defmodule RutviExercise.Runtime.Delegation do
  alias RutviExercise.{Runtime, Store}

  def child(task, service, payload, key, options \\ []) do
    opts = [
      parent_id: task.task_id,
      idempotency_key: "#{task.task_id}:#{key}",
      purpose: key,
      delegation_reason: Keyword.get(options, :delegation_reason, "delegation #{key}"),
      context_pack: Keyword.get(options, :context_pack, task.context_pack),
      concurrency_limit: task.execution[:concurrency_limit] || 2
    ]

    with {:ok, handle} <- Runtime.start(service, payload, Runtime.caller(task), opts) do
      Store.transact(fn data ->
        t = data.tasks[task.task_id]

        if Runtime.terminal?(t.status),
          do: {:ok, data},
          else:
            {:ok,
             Runtime.put_task(data, %{t | status: :waiting_for_children}, :waiting_for_children)}
      end)

      await_child(task, handle.task_id)
    end
  end

  defp await_child(task, id) do
    with {:ok, snapshot} <- Runtime.wait(id, Runtime.caller(task), 100) do
      case snapshot.status do
        :completed ->
          Store.transact(fn data ->
            parent = data.tasks[task.task_id]

            if parent.attempt == task.attempt and !Runtime.terminal?(parent.status),
              do: {:ok, Runtime.put_task(data, %{parent | status: :running}, :running)},
              else: {:ok, data}
          end)

          {:ok, snapshot.result}

        status when status in [:failed, :cancelled, :needs_review] ->
          if is_map(snapshot.error),
            do: {:error, Map.put(snapshot.error, :child_task_id, id)},
            else: {:error, {:child_failed, id, snapshot.error}}

        :waiting_for_human ->
          Runtime.pause_for_child(task, id)

        _ when snapshot.waiting_descendants != [] ->
          Runtime.pause_for_child(task, id)

        _ ->
          Runtime.pause_for_child(task, id)
      end
    end
  end
end
