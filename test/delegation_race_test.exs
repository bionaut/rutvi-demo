defmodule RutviExercise.DelegationRaceTest do
  use ExUnit.Case, async: false

  alias RutviExercise.{Runtime, Store}
  alias RutviExercise.Runtime.Delegation
  @caller %{namespace_id: "A", user_id: "alice", session_id: "parallel-race"}

  defmodule Slow do
    use Synaptic.Workflow

    step :slow do
      Process.sleep(5_000)
      {:ok, %{result: context.input}}
    end

    commit()
  end

  test "a completed parallel child cannot erase another child's suspension or queued replay" do
    parent_service = Store.id()
    fast_service = Store.id()
    slow_service = Store.id()

    for {id, workflow, allowed} <- [
          {parent_service, Slow, [fast_service, slow_service]},
          {fast_service, RutviExercise.Workflows.Echo, []},
          {slow_service, Slow, []}
        ] do
      assert {:ok, _} =
               Runtime.register_service(%{
                 service_id: id,
                 capabilities: [id],
                 namespace: "A",
                 owner: "alice",
                 workflow: workflow,
                 allowed_services: allowed
               })
    end

    {:ok, root} = Runtime.start(parent_service, %{}, @caller)
    on_exit(fn -> Runtime.cancel(root.task_id, @caller) end)
    {:ok, _} = Runtime.wait(root.task_id, @caller, 20)
    task = Store.read(& &1.tasks[root.task_id])
    _ = Delegation.child(task, fast_service, %{"message" => "ready"}, "fast")

    fast =
      Store.read(fn data ->
        Enum.find(
          Map.values(data.tasks),
          &(&1.parent_id == task.task_id and &1.service_id == fast_service)
        )
      end)

    assert {:ok, %{status: :completed}} = Runtime.wait(fast.task_id, @caller, 1_000)
    {:ok, slow} = Runtime.start(slow_service, %{}, @caller, parent_id: task.task_id)
    assert {:error, :waiting_for_children} = Runtime.pause_for_child(task, slow.task_id)

    assert {:ok, %{"message" => "ready"}} =
             Delegation.child(task, fast_service, %{"message" => "ready"}, "fast")

    assert {:ok, %{status: :waiting_for_children, paused_on_child: slow_id}} =
             Runtime.inspect(task.task_id, @caller)

    assert slow_id == slow.task_id

    # A child can finish before its waiter persists the suspension. That queues
    # replay; a concurrently completed sibling must not turn it back to running.
    assert {:error, :waiting_for_children} = Runtime.pause_for_child(task, fast.task_id)

    assert {:ok, %{"message" => "ready"}} =
             Delegation.child(task, fast_service, %{"message" => "ready"}, "fast")

    assert {:ok, %{status: :queued}} = Runtime.inspect(task.task_id, @caller)
  end
end
