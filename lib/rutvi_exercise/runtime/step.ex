defmodule RutviExercise.Runtime.Step do
  alias RutviExercise.{Store, Runtime}

  def run(task, key, fun, schema \\ %{}) do
    case Store.read(& &1.tasks[task.task_id].steps[key]) do
      %{output: output} ->
        {:ok, output}

      nil ->
        before = Store.read(& &1.tasks[task.task_id])

        result =
          case fun.() do
            {:ok, output} = success ->
              if RutviExercise.Runtime.Schema.validate(output, schema) == :ok,
                do: success,
                else: {:error, :validation_error}

            other ->
              other
          end

        case result do
          {:ok, output} ->
            accepted =
              Store.transact(fn data ->
                t = data.tasks[task.task_id]

                cond do
                  t.attempt != task.attempt or Runtime.terminal?(t.status) ->
                    {{:error, :stale_attempt}, data}

                  Map.has_key?(t.steps, key) ->
                    {{:ok, t.steps[key].output}, data}

                  true ->
                    t = %{
                      t
                      | steps: Map.put(t.steps, key, %{output: output, attempt: task.attempt})
                    }

                    {{:ok, output},
                     Runtime.put_task(data, t, :step_completed, %{
                       step: key,
                       attempt: task.attempt,
                       artifact_id: Store.id()
                     })}
                end
              end)

            if match?({:ok, _}, accepted) do
              if observer = Application.get_env(:rutvi_exercise, :step_observer),
                do: observer.(task, key, output)

              evaluate(before, output, key)
            end

            accepted

          other ->
            other
        end
    end
  end

  defp evaluate(before, output, key) do
    if evaluator = Application.get_env(:rutvi_exercise, :evaluator) do
      Task.Supervisor.start_child(RutviExercise.Evaluators, fn ->
        try do
          after_snapshot = Store.read(& &1.tasks[before.task_id])
          result = evaluator.evaluate(before, after_snapshot, output)

          Store.transact(fn data ->
            {:ok,
             Store.event(data, data.tasks[before.task_id], :evaluation, %{
               step: key,
               evaluation: result
             })}
          end)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)
    end
  end

  @doc "Durable parallel branch adapter. Each branch sees the same immutable snapshot; merge follows declaration order."
  def parallel(task, key, snapshot, branches) do
    tasks =
      Enum.map(branches, fn {name, fun} ->
        Task.Supervisor.async_nolink(RutviExercise.DomainWorkers, fn ->
          run(task, {key, name}, fn -> fun.(snapshot) end)
        end)
      end)

    Task.await_many(tasks, 60_000)
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, output}, {:ok, acc} ->
        case merge(acc, output) do
          {:ok, _} = next -> {:cont, next}
          error -> {:halt, error}
        end

      error, _ ->
        {:halt, error}
    end)
  end

  def route(route, branches) do
    case Map.fetch(branches, route) do
      {:ok, fun} -> fun.()
      :error -> {:error, :invalid_route}
    end
  end

  def merge(left, right) do
    if Enum.any?(Map.keys(right), fn k -> Map.has_key?(left, k) and left[k] != right[k] end),
      do: {:error, :context_conflict},
      else: {:ok, Map.merge(left, right)}
  end
end
