defmodule RutviExercise.Runtime.Model do
  alias RutviExercise.{Store, Runtime, Runtime.Schema, Runtime.Step}

  def generate(task, interaction, prompt, schema, metadata \\ %{}) do
    current = Store.read(& &1.tasks[task.task_id])

    if current.attempt != task.attempt or Runtime.terminal?(current.status) do
      {:error, :stale_attempt}
    else
      generate_active(task, interaction, prompt, schema, metadata)
    end
  end

  defp generate_active(task, interaction, prompt, schema, metadata) do
    service = Store.read(& &1.services[task.service_id])

    defaults = %{
      model: Application.get_env(:rutvi_exercise, :model, "gpt-6.1-sol"),
      reasoning_effort: Application.get_env(:rutvi_exercise, :reasoning_effort, "medium"),
      timeout_ms: 10_000,
      tool_timeout_ms: 5_000
    }

    settings =
      defaults
      |> Map.merge(Application.get_env(:rutvi_exercise, :model_defaults, %{}))
      |> Map.merge(service.model_profile)

    override =
      Map.take(task.execution[:model_override] || %{}, service[:allowed_model_overrides] || [])

    settings = Map.merge(settings, override)

    request =
      Map.merge(metadata, %{
        messages: [
          %{role: :system, content: prompt},
          %{
            role: :user,
            content:
              Jason.encode!(
                task.input
                |> Map.put("sources", metadata[:sources] || [])
                |> Map.put(
                  "available_tools",
                  RutviExercise.Runtime.Tools.definitions(service.allowed_tools)
                )
              )
          }
        ],
        output_schema: schema,
        task_id: task.task_id,
        role: task.service_id,
        revision: task.revision,
        tools: RutviExercise.Runtime.Tools.definitions(service.allowed_tools),
        interaction: interaction
      })

    loop(task, interaction, 0, 0, request, schema, settings, service)
  end

  defp loop(task, interaction, turn, round, request, schema, settings, service) do
    case provider(task, interaction, turn, request, settings, 1) do
      {:ok, %{tool_calls: calls}} when is_list(calls) ->
        if round >= 4 do
          {:error, :limit_exceeded}
        else
          outputs =
            Enum.map(calls, fn call ->
              Step.run(task, {:tool, interaction, turn, call[:call_id] || call["call_id"]}, fn ->
                {:ok, tool(task, service, call, settings)}
              end)
              |> case do
                {:ok, output} -> output
                error -> %{call_id: call[:call_id] || call["call_id"], result: error}
              end
            end)

          loop(
            task,
            interaction,
            turn + 1,
            round + 1,
            request
            |> Map.put(:tool_results, outputs)
            |> Map.update!(:messages, fn messages ->
              messages ++
                [
                  %{role: :assistant, content: Jason.encode!(%{tool_calls: calls})},
                  %{role: :user, content: Jason.encode!(Enum.map(outputs, &tool_message/1))}
                ]
            end),
            schema,
            settings,
            service
          )
        end

      {:ok, %{output: output}} ->
        with :ok <- Schema.validate(output, schema), do: {:ok, output}

      other ->
        other
    end
  end

  defp provider(task, interaction, turn, request, settings, attempt) do
    cached = Store.read(&Map.get(&1.counters, {:response, task.task_id, interaction, turn}))

    if cached do
      {:ok, cached}
    else
      case reserve(task, interaction, turn, attempt) do
        {:ok, persisted_attempt} ->
          adapter =
            Application.get_env(:rutvi_exercise, :model_adapter, RutviExercise.Models.Codex)

          response =
            timed(
              fn ->
                adapter.generate(
                  transport_request(
                    adapter,
                    Map.merge(request, %{turn: turn, attempt: persisted_attempt})
                  ),
                  if(adapter in [RutviExercise.Models.Codex, RutviExercise.Models.RemoteCodex],
                    do: [timeout_ms: settings.timeout_ms],
                    else: Map.to_list(settings)
                  )
                )
              end,
              settings.timeout_ms,
              task
            )

          output =
            case normalize(response, adapter) do
              {:ok, %{output: out}} = success ->
                case validate_output(out, request) do
                  :ok ->
                    success

                  {:error, details} ->
                    {:error, %{code: :invalid_output, retryable: true, details: details}}
                end

              other ->
                other
            end

          Store.transact(fn data ->
            current = data.tasks[task.task_id]

            output =
              if current.attempt == task.attempt and !Runtime.terminal?(current.status),
                do: output,
                else: {:error, :stale_attempt}

            data =
              case output do
                {:ok, response} ->
                  %{
                    data
                    | counters:
                        Map.put(
                          data.counters,
                          {:response, task.task_id, interaction, turn},
                          response
                        )
                  }

                _ ->
                  data
              end

            {:ok,
             Store.event(data, data.tasks[task.task_id], :model_response, %{
               interaction: interaction,
               turn: turn,
               attempt: persisted_attempt,
               model: settings.model,
               settings:
                 Map.take(settings, [
                   :model,
                   :temperature,
                   :reasoning_effort,
                   :timeout_ms,
                   :tool_timeout_ms,
                   :profile
                 ]),
               outcome: outcome(output),
               usage:
                 case output do
                   {:ok, response} -> response[:usage]
                   _ -> nil
                 end,
               reasoning_effort:
                 case output do
                   {:ok, response} -> response[:reasoning_effort]
                   _ -> nil
                 end,
               validation_error:
                 case output do
                   {:error, %{code: :invalid_output} = error} ->
                     error[:details] || error[:message]

                   _ ->
                     nil
                 end
             })}
          end)

          if observer = Application.get_env(:rutvi_exercise, :model_observer),
            do: observer.(task, interaction, turn, persisted_attempt, output)

          case output do
            {:error, %{retryable: true} = error} when persisted_attempt < 3 ->
              Process.sleep(Application.get_env(:rutvi_exercise, :retry_delay_ms, 25))

              provider(
                task,
                interaction,
                turn,
                retry_feedback(request, error),
                settings,
                attempt + 1
              )

            other ->
              other
          end

        error ->
          error
      end
    end
  end

  defp validate_output(output, request) do
    case ExJsonSchema.Validator.validate(
           ExJsonSchema.Schema.resolve(request.output_schema),
           output
         ) do
      :ok ->
        if validator = request[:output_validator], do: validator.(output), else: :ok

      {:error, errors} ->
        {:error, Kernel.inspect(errors, limit: 12, printable_limit: 1500)}
    end
  end

  defp retry_feedback(request, %{code: :invalid_output} = error) do
    message =
      "The previous response failed local validation. Return a corrected response using the exact final schema and transport envelope. Do not add fields. Validation: " <>
        Kernel.inspect(error[:details] || error[:message] || :invalid_output,
          printable_limit: 1500
        )

    Map.update!(request, :messages, &(&1 ++ [%{role: :user, content: message}]))
  end

  defp retry_feedback(request, _), do: request

  defp transport_request(adapter, request)
       when adapter in [RutviExercise.Models.Codex, RutviExercise.Models.RemoteCodex],
       do: RutviExercise.Runtime.CodexProtocol.encode(request)

  defp transport_request(_, request), do: request

  defp normalize(response, adapter)
       when adapter in [RutviExercise.Models.Codex, RutviExercise.Models.RemoteCodex],
       do: RutviExercise.Runtime.CodexProtocol.decode(response)

  defp normalize({:ok, %{output: %{"tool_calls" => calls}} = response}, _) when is_list(calls),
    do: {:ok, response |> Map.delete(:output) |> Map.put(:tool_calls, calls)}

  defp normalize(response, _), do: response

  defp tool_message(%{call_id: id, result: {:ok, value}}), do: %{call_id: id, result: value}

  defp tool_message(%{call_id: id, result: {:error, error}}),
    do: %{call_id: id, error: if(is_atom(error), do: Atom.to_string(error), else: error)}

  defp outcome({:ok, r}),
    do: Map.take(r, [:model, :usage, :reasoning_effort]) |> Map.put(:status, :ok)

  defp outcome({:error, e}), do: %{status: :error, error: e}

  defp reserve(task, interaction, turn, _attempt) do
    Store.transact(fn data ->
      t = data.tasks[task.task_id]
      total = {:requests, task.task_id, interaction}
      key = {:attempts, task.task_id, interaction, turn}

      cond do
        t.attempt != task.attempt or Runtime.terminal?(t.status) ->
          {{:error, :stale_attempt}, data}

        Map.get(data.counters, total, 0) >= 15 or Map.get(data.counters, key, 0) >= 3 ->
          {{:error, :limit_exceeded}, data}

        true ->
          counters =
            data.counters |> Map.update(total, 1, &(&1 + 1)) |> Map.update(key, 1, &(&1 + 1))

          {{:ok, counters[key]},
           Store.event(%{data | counters: counters}, t, :provider_reserved, %{
             interaction: interaction,
             turn: turn,
             attempt: counters[key]
           })}
      end
    end)
  end

  defp acquire(task) do
    token = {task.task_id, task.attempt, self()}

    result =
      Store.transact(fn data ->
        key = {:active, task.run_id}
        leases = Map.get(data.counters, key, MapSet.new())
        active = MapSet.size(leases)
        root = Enum.find(Map.values(data.tasks), &(&1.run_id == task.run_id and &1.depth == 0))
        max_calls = root.execution[:concurrency_limit] || 2

        if Runtime.terminal?(data.tasks[task.task_id].status) or
             data.tasks[task.task_id].attempt != task.attempt,
           do: {{:error, :cancelled}, data},
           else:
             if(active < max_calls,
               do:
                 {:ok,
                  Store.event(
                    %{data | counters: Map.put(data.counters, key, MapSet.put(leases, token))},
                    data.tasks[task.task_id],
                    :external_started,
                    %{active_count: active + 1}
                  )},
               else: {:busy, data}
             )
      end)

    case result do
      :busy ->
        Process.sleep(5)
        acquire(task)

      :ok ->
        :ok

      error ->
        throw(error)
    end
  end

  defp release(task, owner) do
    token = {task.task_id, task.attempt, owner}

    Store.transact(fn data ->
      key = {:active, task.run_id}
      leases = Map.get(data.counters, key, MapSet.new())

      if MapSet.member?(leases, token) do
        {:ok,
         Store.event(
           %{data | counters: Map.put(data.counters, key, MapSet.delete(leases, token))},
           data.tasks[task.task_id],
           :external_finished
         )}
      else
        {:ok, data}
      end
    end)
  end

  defp timed(fun, timeout, owner_task) do
    caller = self()

    external =
      Task.Supervisor.async_nolink(RutviExercise.External, fn ->
        acquire(owner_task)
        external_pid = self()

        {:ok, watchdog} =
          Task.Supervisor.start_child(RutviExercise.ControlWorkers, fn ->
            receive do
              :done -> :ok
            after
              timeout -> Process.exit(external_pid, :kill)
            end

            release(owner_task, external_pid)
          end)

        send(caller, {:external_ready, external_pid})

        try do
          safe_external_call(fun)
        after
          send(watchdog, :done)
        end
      end)

    receive do
      {:external_ready, pid} when pid == external.pid ->
        case Task.yield(external, timeout) || Task.shutdown(external, :brutal_kill) do
          {:ok, result} ->
            result

          {:exit, :killed} ->
            release(owner_task, external.pid)
            {:error, %{code: :timeout, retryable: true}}

          {:exit, _reason} ->
            release(owner_task, external.pid)
            {:error, %{code: :provider_exception, retryable: false}}

          _ ->
            release(owner_task, external.pid)
            {:error, %{code: :timeout, retryable: true}}
        end

      {:DOWN, ref, :process, _, _} when ref == external.ref ->
        {:error, %{code: :cancelled, retryable: false}}
    end
  end

  defp safe_external_call(fun) do
    fun.()
  rescue
    _ ->
      {:error,
       %{
         code: :provider_exception,
         message: "The external adapter failed before returning a response.",
         retryable: false
       }}
  catch
    _, _ ->
      {:error,
       %{
         code: :provider_exception,
         message: "The external adapter terminated before returning a response.",
         retryable: false
       }}
  end

  defp tool(task, service, call, settings) do
    id = call[:call_id] || call["call_id"]
    name = call[:name] || call["name"]
    args = call[:arguments] || call["arguments"]

    result =
      cond do
        name not in service.allowed_tools ->
          {:error, :forbidden}

        true ->
          timed(
            fn -> RutviExercise.Runtime.Tools.invoke(name, args, task) end,
            settings.tool_timeout_ms,
            task
          )
      end

    %{call_id: id, result: result}
  end
end
