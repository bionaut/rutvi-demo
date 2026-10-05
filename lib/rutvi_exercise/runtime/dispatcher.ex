defmodule RutviExercise.Runtime.Dispatcher do
  use GenServer
  alias RutviExercise.{Store, Runtime}
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def kick(id), do: GenServer.cast(__MODULE__, {:kick, id})
  def cancel(id), do: GenServer.cast(__MODULE__, {:cancel, id})

  def init(_) do
    send(self(), :recover)
    {:ok, %{}}
  end

  def handle_cast({:kick, id}, state) do
    if Map.has_key?(state, id) do
      {:noreply, state}
    else
      claim =
        Store.transact(fn data ->
          case data.tasks[id] do
            %{status: :queued} = t ->
              t = %{t | status: :running, attempt: t.attempt + 1}

              {{:ok, t, data.services[t.service_id]},
               Runtime.put_task(data, t, :running, %{attempt: t.attempt})}

            _ ->
              {:skip, data}
          end
        end)

      case claim do
        {:ok, t, s} ->
          task = Task.Supervisor.async_nolink(RutviExercise.Workers, fn -> execute(t, s) end)
          {:noreply, Map.put(state, id, task)}

        _ ->
          {:noreply, state}
      end
    end
  end

  def handle_cast({:cancel, id}, state) do
    ids = Store.read(&Runtime.descendants(&1, id))

    Enum.each(ids, fn task_id ->
      t = Store.read(& &1.tasks[task_id])

      Task.Supervisor.start_child(RutviExercise.ControlWorkers, fn ->
        try do
          Synaptic.stop("#{task_id}-#{t.attempt - 1}")
        catch
          :exit, _ -> :ok
        end
      end)
    end)

    state =
      Enum.reduce(ids, state, fn i, acc ->
        case Map.pop(acc, i) do
          {nil, rest} ->
            rest

          {task, rest} ->
            Task.shutdown(task, :brutal_kill)
            rest
        end
      end)

    {:noreply, state}
  end

  def handle_info(:recover, state) do
    ids =
      Store.transact(fn data ->
        ids =
          for {id, t} <- data.tasks,
              !Runtime.terminal?(t.status) and t.status != :waiting_for_human,
              do: id

        data =
          Enum.reduce(ids, data, fn id, d ->
            t = d.tasks[id]
            Runtime.put_task(d, %{t | status: :queued, attempt: t.attempt + 1}, :recovered)
          end)

        counters =
          Enum.reject(data.counters, fn {k, _} -> match?({:active, _}, k) end) |> Map.new()

        {ids, %{data | counters: counters}}
      end)

    Enum.each(ids, &kick/1)
    {:noreply, state}
  end

  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    ids = for {id, t} <- state, t.ref == ref, do: id
    Enum.each(ids, fn id -> if Store.read(& &1.tasks[id].status) == :queued, do: kick(id) end)
    {:noreply, Enum.reject(state, fn {_, t} -> t.ref == ref end) |> Map.new()}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    case Enum.find(state, fn {_, t} -> t.ref == ref end) do
      {id, _} ->
        Store.transact(fn data ->
          t = data.tasks[id]

          if Runtime.terminal?(t.status),
            do: {:ok, data},
            else:
              {:ok, Runtime.put_task(data, %{t | status: :queued, error: reason}, :worker_down)}
        end)

        kick(id)
        {:noreply, Map.delete(state, id)}

      nil ->
        {:noreply, state}
    end
  end

  defp execute(t, s) do
    run = "#{t.task_id}-#{t.attempt}"

    case Synaptic.start(s.workflow, %{task: t, input: t.input, attempt: t.attempt}, run_id: run) do
      {:ok, _} -> poll(run, t, s)
      error -> finish(t, :failed, nil, error)
    end
  rescue
    error -> finish(t, :failed, nil, Exception.message(error))
  end

  defp poll(run, t, s) do
    case Synaptic.inspect(run, :infinity) do
      %{status: :completed, context: context} ->
        result = Map.get(context, :result, Map.drop(context, [:task, :input, :attempt]))

        case RutviExercise.Runtime.Schema.validate(result, s.output_schema) do
          :ok -> finish(t, :completed, result, nil)
          error -> finish(t, :failed, nil, error)
        end

      %{status: status} when status in [:failed, :cancelled, :stopped] ->
        current = Store.read(& &1.tasks[t.task_id])

        reason = Map.get(Synaptic.inspect(run, :infinity), :last_error, :workflow_failed)

        if current.status != :waiting_for_human and reason != :waiting_for_children,
          do:
            finish(
              t,
              :failed,
              nil,
              reason
            )

      _ ->
        current = Store.read(& &1.tasks[t.task_id])

        if current.attempt == t.attempt and !Runtime.terminal?(current.status) and
             current.status != :waiting_for_human do
          Process.sleep(10)
          poll(run, t, s)
        end
    end
  end

  def finish(t, status, result, error) do
    accepted =
      Store.transact(fn data ->
        current = data.tasks[t.task_id]

        if current.attempt != t.attempt or Runtime.terminal?(current.status) or
             current.status == :waiting_for_human do
          {{:error, :stale_attempt}, data}
        else
          children = Enum.filter(Map.values(data.tasks), &(&1.parent_id == t.task_id))

          if status == :completed and Enum.any?(children, &(&1.status != :completed)) do
            {:ok,
             Runtime.put_task(
               data,
               %{current | status: :failed, error: :unfinished_children},
               :failed
             )}
          else
            {:ok,
             Runtime.put_task(
               data,
               %{current | status: status, result: result, error: error},
               status
             )}
          end
        end
      end)

    if accepted == :ok and Store.read(& &1.tasks[t.task_id].status) == :failed,
      do: Runtime.cancel(t.task_id, Runtime.caller(t))

    if accepted == :ok do
      parent_id = t.parent_id

      if parent_id do
        wake =
          Store.transact(fn data ->
            parent = data.tasks[parent_id]

            if parent.status == :waiting_for_children and
                 Map.get(parent, :paused_on_child) == t.task_id do
              parent = parent |> Map.put(:status, :queued) |> Map.put(:paused_on_child, nil)
              {true, Runtime.put_task(data, parent, :child_finished, %{child_task_id: t.task_id})}
            else
              {false, data}
            end
          end)

        if wake, do: kick(parent_id)
      end
    end

    accepted
  end
end
