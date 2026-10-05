defmodule RutviExercise.Runtime do
  import Kernel, except: [inspect: 2]

  @moduledoc "Authenticated routing and durable task control; execution is delegated to Synaptic workflows."
  alias RutviExercise.{Store, Runtime.Schema}
  @terminal [:completed, :failed, :cancelled, :needs_review]
  def delegate(task, target, payload, key, opts \\ []),
    do: RutviExercise.Runtime.Delegation.child(task, target, payload, key, opts)

  def register_tool(definition), do: RutviExercise.Runtime.Tools.register(definition)

  def workflow_definition(service_id),
    do:
      Store.read(fn data ->
        case data.services[service_id] do
          nil -> {:error, :not_found}
          s -> {:ok, Synaptic.workflow_definition(s.workflow)}
        end
      end)

  def ready?,
    do:
      is_pid(Process.whereis(Store)) and is_pid(Process.whereis(RutviExercise.Runtime.Dispatcher))

  def terminal?(status), do: status in @terminal

  def register_service(definition) do
    required = [:service_id, :capabilities, :namespace, :owner, :workflow]

    if Enum.all?(required, &Map.has_key?(definition, &1)) do
      defn =
        Map.merge(
          %{
            visibility: :namespace,
            lifecycle: :isolated,
            input_schema: %{},
            output_schema: %{},
            allowed_services: [],
            allowed_tools: [],
            model_profile: %{}
          },
          definition
        )

      Store.transact(fn data ->
        case data.services[defn.service_id] do
          nil -> {{:ok, defn}, %{data | services: Map.put(data.services, defn.service_id, defn)}}
          ^defn -> {{:ok, defn}, data}
          _ -> {{:error, :conflict}, data}
        end
      end)
    else
      {:error, :validation_error}
    end
  end

  def start(target, payload, caller, opts \\ []) do
    result = Store.transact(fn data -> create(data, target, payload, caller, Map.new(opts)) end)

    case result do
      {:ok, task} ->
        RutviExercise.Runtime.Dispatcher.kick(task.task_id)
        {:ok, snapshot(task)}

      error ->
        error
    end
  end

  defp create(data, target, payload, caller, opts) do
    with :ok <- identity(caller),
         {:ok, service} <- route(data, target, caller),
         :ok <- Schema.validate(payload, service.input_schema),
         {:ok, parent} <- parent(data, opts[:parent_id], caller),
         :ok <- allowed(data, parent, service) do
      scope = {caller.namespace_id, caller.user_id, service.service_id}
      key = if opts[:idempotency_key], do: {scope, opts.idempotency_key}
      canonical = {payload, Map.drop(opts, [:idempotency_key])}
      existing = (key && data.keys[key]) || reuse(data, service, payload, caller, opts)

      cond do
        existing && data.tasks[existing].canonical != canonical ->
          {{:error, :conflict}, data}

        existing ->
          {{:ok, data.tasks[existing]}, data}

        parent && parent.depth >= 4 ->
          {{:error, :limit_exceeded}, data}

        parent &&
            Enum.count(data.tasks, fn {_, t} ->
              t.run_id == parent.run_id and t.parent_id != nil
            end) >= 20 ->
          {{:error, :limit_exceeded}, data}

        true ->
          id = Store.id()
          now = System.system_time(:microsecond)

          task = %{
            task_id: id,
            reference_id: id,
            run_id: (parent && parent.run_id) || Store.id(),
            request_id: (parent && parent.request_id) || Map.get(caller, :request_id, Store.id()),
            parent_id: opts[:parent_id],
            depth: if(parent, do: parent.depth + 1, else: 0),
            service_id: service.service_id,
            namespace_id: caller.namespace_id,
            user_id: caller.user_id,
            session_id: caller.session_id,
            caller_service_id:
              if(parent, do: parent.service_id, else: Map.get(caller, :caller_service_id)),
            purpose: opts[:purpose],
            aliases: opts[:aliases] || [],
            reuse_key: opts[:reuse_key],
            delegation_reason: opts[:delegation_reason],
            context_pack: opts[:context_pack] || %{},
            created_at: now,
            updated_at: now,
            input: payload,
            status: :queued,
            result: nil,
            error: nil,
            attempt: 0,
            steps: %{},
            checkpoints: [],
            canonical: canonical,
            execution: opts,
            revision: 0
          }

          data = %{
            data
            | tasks: Map.put(data.tasks, id, task),
              keys: if(key, do: Map.put(data.keys, key, id), else: data.keys)
          }

          {{:ok, task}, Store.event(data, task, :queued)}
      end
    else
      error -> {error, data}
    end
  end

  defp identity(%{namespace_id: ns, user_id: user, session_id: session})
       when is_binary(ns) and is_binary(user) and is_binary(session),
       do: :ok

  defp identity(_), do: {:error, :forbidden}

  defp visible?(s, c),
    do: s.namespace == c.namespace_id and (s.visibility == :namespace or s.owner == c.user_id)

  defp route(data, target, caller) do
    matches =
      case target do
        id when is_binary(id) -> Enum.filter(Map.values(data.services), &(&1.service_id == id))
        %{capability: cap} -> Enum.filter(Map.values(data.services), &(cap in &1.capabilities))
        _ -> []
      end

    visible = Enum.filter(matches, &visible?(&1, caller))

    case visible do
      [one] -> {:ok, one}
      [] -> {:error, if(matches == [], do: :not_found, else: :forbidden)}
      _ -> {:error, :ambiguous_target}
    end
  end

  defp parent(_data, nil, _caller), do: {:ok, nil}
  defp parent(data, id, caller), do: fetch(data, id, caller)
  defp allowed(_data, nil, _service), do: :ok

  defp allowed(data, parent, service) do
    cond do
      terminal?(parent.status) ->
        {:error, :conflict}

      service.service_id not in data.services[parent.service_id].allowed_services ->
        {:error, :forbidden}

      true ->
        :ok
    end
  end

  defp reuse(data, %{lifecycle: :session} = s, _payload, c, %{reuse_key: key} = opts) do
    Enum.find_value(data.tasks, fn {id, t} ->
      if !terminal?(t.status) and
           {t.namespace_id, t.user_id, t.session_id, t.service_id, t.purpose, t.reuse_key,
            t.parent_id} ==
             {c.namespace_id, c.user_id, c.session_id, s.service_id, opts[:purpose], key,
              opts[:parent_id]},
         do: id
    end)
  end

  defp reuse(_, _, _, _, _), do: nil

  def fetch(data, id, caller) do
    case data.tasks[id] do
      nil ->
        {:error, :not_found}

      task ->
        if task.namespace_id == caller[:namespace_id] and task.user_id == caller[:user_id],
          do: {:ok, task},
          else: {:error, :forbidden}
    end
  end

  def inspect(ref, caller),
    do:
      Store.read(fn data ->
        with {:ok, t} <- fetch(data, ref, caller), do: {:ok, enriched(data, t)}
      end)

  def history(ref, caller, after_seq \\ 0),
    do:
      Store.read(fn data ->
        with {:ok, t} <- fetch(data, ref, caller),
             do:
               {:ok,
                Enum.filter(data.events, &(&1.run_id == t.run_id and &1.sequence > after_seq))}
      end)

  def wait(ref, caller, timeout \\ 0) do
    deadline = System.monotonic_time(:millisecond) + max(timeout, 0)
    await(ref, caller, deadline)
  end

  defp await(ref, caller, deadline) do
    case inspect(ref, caller) do
      {:ok, t} = result ->
        if terminal?(t.status) or t.status == :waiting_for_human or
             t.waiting_descendants != [] or
             System.monotonic_time(:millisecond) >= deadline,
           do: result,
           else:
             (
               Process.sleep(10)
               await(ref, caller, deadline)
             )

      error ->
        error
    end
  end

  def resolve(query, caller) do
    Store.read(fn data ->
      tasks =
        Enum.filter(Map.values(data.tasks), fn t ->
          t.namespace_id == caller[:namespace_id] and t.user_id == caller[:user_id] and
            Enum.all?(Map.drop(query, [:latest, :active_only]), fn
              {:alias, v} -> v in t.aliases
              {:capability, v} -> v in data.services[t.service_id].capabilities
              {k, v} -> Map.get(t, k) == v
            end) and (!query[:active_only] or !terminal?(t.status))
        end)

      case Enum.sort_by(tasks, &{&1.created_at, &1.task_id}, :desc) do
        [] ->
          {:error, :not_found}

        [one] ->
          {:ok, enriched(data, one)}

        [one | _] ->
          if(query[:latest], do: {:ok, enriched(data, one)}, else: {:error, :ambiguous_reference})
      end
    end)
  end

  def cancel(ref, caller) do
    result =
      Store.transact(fn data ->
        with {:ok, t} <- fetch(data, ref, caller) do
          ids = descendants(data, ref)

          data =
            Enum.reduce(ids, data, fn id, d ->
              task = d.tasks[id]

              if terminal?(task.status),
                do: d,
                else:
                  put_task(d, %{task | status: :cancelled, attempt: task.attempt + 1}, :cancelled)
            end)

          {{:ok, enriched(data, data.tasks[t.task_id])}, data}
        else
          error -> {error, data}
        end
      end)

    if match?({:ok, _}, result), do: RutviExercise.Runtime.Dispatcher.cancel(ref)
    result
  end

  def descendants(data, id),
    do: [
      id
      | Enum.flat_map(
          Enum.filter(Map.values(data.tasks), &(&1.parent_id == id)),
          &descendants(data, &1.task_id)
        )
    ]

  def checkpoint(id, attempt, key, message, schema, metadata \\ %{}) do
    Store.transact(fn data ->
      t = data.tasks[id]
      existing = Enum.find(t.checkpoints, &(&1.key == key))

      cond do
        t.attempt != attempt or terminal?(t.status) ->
          {{:error, :stale_attempt}, data}

        existing && existing.response ->
          {{:ok, existing.response.payload}, data}

        existing ->
          {{:waiting, existing}, data}

        true ->
          cp = %{
            checkpoint_id: Store.id(),
            task_id: id,
            key: key,
            message: message,
            metadata: metadata,
            resume_schema: schema,
            response: nil
          }

          t = %{t | checkpoints: t.checkpoints ++ [cp], status: :waiting_for_human}
          {{:waiting, cp}, put_task(data, t, :waiting_for_human)}
      end
    end)
  end

  def pause_for_child(task, child_id) do
    result =
      Store.transact(fn data ->
        current = data.tasks[task.task_id]

        if current.attempt == task.attempt and !terminal?(current.status) do
          child = data.tasks[child_id]

          current =
            if terminal?(child.status) do
              current |> Map.put(:status, :queued) |> Map.put(:paused_on_child, nil)
            else
              current
              |> Map.put(:status, :waiting_for_children)
              |> Map.put(:paused_on_child, child_id)
            end

          {{:error, :waiting_for_children},
           put_task(data, current, :waiting_for_children, %{child_task_id: child_id})}
        else
          {{:error, :stale_attempt}, data}
        end
      end)

    if Store.read(& &1.tasks[task.task_id].status) == :queued,
      do: RutviExercise.Runtime.Dispatcher.kick(task.task_id)

    result
  end

  def resume(ref, checkpoint_id, response_id, payload, caller) do
    result =
      Store.transact(fn data ->
        with {:ok, root} <- fetch(data, ref, caller),
             cp when not is_nil(cp) <-
               descendants(data, ref)
               |> Enum.flat_map(&data.tasks[&1].checkpoints)
               |> Enum.find(&(&1.checkpoint_id == checkpoint_id)),
             :ok <- Schema.validate(payload, cp.resume_schema) do
          task = data.tasks[cp.task_id]

          cond do
            cp.response == %{response_id: response_id, payload: payload} ->
              {{:ok, enriched(data, root), task.task_id}, data}

            cp.response || terminal?(task.status) || terminal?(root.status) ->
              {{:error, :conflict}, data}

            true ->
              cp = %{cp | response: %{response_id: response_id, payload: payload}}

              task = %{
                task
                | status: :queued,
                  checkpoints:
                    Enum.map(task.checkpoints, fn old ->
                      if old.checkpoint_id == checkpoint_id, do: cp, else: old
                    end)
              }

              data = put_task(data, task, :resumed)
              {{:ok, enriched(data, data.tasks[root.task_id]), task.task_id}, data}
          end
        else
          nil -> {{:error, :not_found}, data}
          error -> {error, data}
        end
      end)

    case result do
      {:ok, snapshot, id} ->
        RutviExercise.Runtime.Dispatcher.kick(id)
        {:ok, snapshot}

      error ->
        error
    end
  end

  def put_task(data, t, type, details \\ %{}),
    do:
      Store.event(
        %{
          data
          | tasks:
              Map.put(data.tasks, t.task_id, %{t | updated_at: System.system_time(:microsecond)})
        },
        t,
        type,
        details
      )

  def snapshot(t), do: Map.drop(t, [:canonical, :steps, :execution])

  def enriched(data, t) do
    children =
      Enum.filter(Map.values(data.tasks), &(&1.parent_id == t.task_id)) |> Enum.map(&snapshot/1)

    waiting =
      descendants(data, t.task_id)
      |> Enum.map(&data.tasks[&1])
      |> Enum.filter(&(&1.status == :waiting_for_human and &1.task_id != t.task_id))
      |> Enum.map(&snapshot/1)

    checkpoints = descendants(data, t.task_id) |> Enum.flat_map(&data.tasks[&1].checkpoints)

    snapshot(t)
    |> Map.put(:checkpoints, checkpoints)
    |> Map.put(:children, children)
    |> Map.put(:waiting_descendants, waiting)
  end

  def caller(t),
    do:
      Map.take(t, [:namespace_id, :user_id, :session_id, :request_id])
      |> Map.put(:caller_service_id, t.service_id)
end
