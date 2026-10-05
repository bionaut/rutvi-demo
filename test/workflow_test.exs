defmodule RutviExercise.WorkflowTest do
  use ExUnit.Case, async: false
  alias RutviExercise.{Runtime, Store}
  @caller %{namespace_id: "A", user_id: "alice", session_id: "workflow"}
  defmodule Slow do
    use Synaptic.Workflow

    step :slow do
      Process.sleep(2000)
      {:ok, %{result: context.input}}
    end

    commit()
  end

  defmodule Graph do
    use Synaptic.Workflow
    alias RutviExercise.Runtime.Step

    step :seed do
      Step.run(context.task, :seed, fn -> {:ok, %{seed: 10}} end)
    end

    step :parallel do
      Step.parallel(context.task, :branches, context, [
        {:left,
         fn snapshot ->
           Process.sleep(snapshot.input["left"])
           {:ok, %{left: snapshot.seed + 1}}
         end},
        {:right,
         fn snapshot ->
           Process.sleep(snapshot.input["right"])
           {:ok, %{right: snapshot.seed + 2}}
         end}
      ])
    end

    async_step :async do
      Step.run(context.task, :async, fn ->
        Process.sleep(100)
        {:ok, %{async: 13}}
      end)
    end

    step :independent do
      Step.run(context.task, :independent, fn -> {:ok, %{join: context.left + context.right}} end)
    end

    commit()
  end

  defmodule Conflict do
    use Synaptic.Workflow

    step :conflict do
      RutviExercise.Runtime.Step.parallel(context.task, :branches, context, [
        {:a, fn _ -> {:ok, %{value: 1}} end},
        {:b, fn _ -> {:ok, %{value: 2}} end}
      ])
    end

    commit()
  end

  def register(id, module),
    do:
      Runtime.register_service(%{
        service_id: id,
        capabilities: [id],
        namespace: "A",
        owner: "alice",
        workflow: module
      })

  test "K06 sequencing, same branch snapshot, deterministic join and async completion" do
    id = Store.id()
    register(id, Graph)

    outputs =
      for delays <- [%{"left" => 40, "right" => 1}, %{"left" => 1, "right" => 40}] do
        {:ok, t} = Runtime.start(id, delays, @caller)
        Process.sleep(75)
        {:ok, s} = Runtime.inspect(t.task_id, @caller)
        assert s.status != :completed
        {:ok, s} = Runtime.wait(t.task_id, @caller, 2000)
        assert s.status == :completed
        assert s.result == %{seed: 10, left: 11, right: 12, async: 13, join: 23}
        s.result
      end

    assert Enum.uniq(outputs) |> length() == 1
  end

  test "K06 explicit conflicting merge fails workflow and unknown branch never executes" do
    id = Store.id()
    register(id, Conflict)
    {:ok, t} = Runtime.start(id, %{}, @caller)
    assert {:ok, %{status: :failed}} = Runtime.wait(t.task_id, @caller, 1000)

    assert {:error, :invalid_route} =
             RutviExercise.Runtime.Step.route("bad", %{
               "good" => fn -> flunk("wrong branch executed") end
             })
  end

  test "K05 depth four is allowed and fifth rejected; 21st child exceeds persisted run count" do
    id = Store.id()

    Runtime.register_service(%{
      service_id: id,
      capabilities: [id],
      namespace: "A",
      owner: "alice",
      workflow: Slow,
      allowed_services: [id]
    })

    {:ok, root} = Runtime.start(id, %{}, @caller)

    last =
      Enum.reduce(1..4, root, fn n, p ->
        {:ok, c} =
          Runtime.start(id, %{}, @caller,
            parent_id: p.task_id,
            idempotency_key: "depth#{root.task_id}:#{n}"
          )

        c
      end)

    assert last.depth == 4
    assert {:error, :limit_exceeded} = Runtime.start(id, %{}, @caller, parent_id: last.task_id)
    Runtime.cancel(root.task_id, @caller)
    {:ok, root} = Runtime.start(id, %{}, @caller)

    for n <- 1..20 do
      assert {:ok, _} =
               Runtime.start(id, %{}, @caller,
                 parent_id: root.task_id,
                 idempotency_key: "count#{root.task_id}:#{n}"
               )
    end

    assert {:error, :limit_exceeded} = Runtime.start(id, %{}, @caller, parent_id: root.task_id)

    {:ok, a} =
      Runtime.start(id, %{}, @caller,
        parent_id: root.task_id,
        idempotency_key: "count#{root.task_id}:1"
      )

    assert a.run_id == root.run_id
    Runtime.cancel(root.task_id, @caller)
  end
end
