defmodule RutviExercise.RecoveryTest do
  use ExUnit.Case, async: false
  alias RutviExercise.{Runtime, Store}
  @caller %{namespace_id: "A", user_id: "alice", session_id: "recovery"}
  defmodule FencedSlow do
    use Synaptic.Workflow

    step :slow do
      Process.sleep(2000)
      {:ok, %{result: context.input}}
    end

    commit()
  end

  defmodule HumanChain do
    use Synaptic.Workflow

    step :chain do
      task = context.task

      case task.input["chain"] do
        [target | rest] ->
          with {:ok, output} <-
                 RutviExercise.Runtime.delegate(task, target, %{"chain" => rest}, "child"),
               do: {:ok, %{result: output}}

        [] ->
          schema =
            RutviExercise.Runtime.Schema.object(
              %{"answer" => RutviExercise.Runtime.Schema.string()},
              ["answer"]
            )

          case RutviExercise.Runtime.checkpoint(
                 task.task_id,
                 task.attempt,
                 :human,
                 "Answer",
                 schema
               ) do
            {:ok, output} -> {:ok, %{result: output}}
            {:waiting, _} -> {:error, :waiting_for_human}
            error -> error
          end
      end
    end

    commit()
  end

  defmodule Evaluator do
    def evaluate(_, _, _), do: raise("isolated evaluator failure")
  end

  test "K07/K12 checkpoints and cursor events survive complete application restart" do
    {:ok, t} = Runtime.start("course.create", %{}, @caller, aliases: ["recover-#{Store.id()}"])
    {:ok, s} = Runtime.wait(t.task_id, @caller, 1000)
    assert s.status == :waiting_for_children
    cp = hd(s.checkpoints)
    assert cp.task_id != t.task_id
    assert hd(s.waiting_descendants).service_id == "course.plan"
    {:ok, events} = Runtime.history(t.task_id, @caller)
    assert :ok = Application.stop(:rutvi_exercise)
    assert :ok = Application.start(:rutvi_exercise)
    assert {:ok, %{run_id: run}} = Runtime.inspect(t.task_id, @caller)
    assert run == t.run_id
    assert {:ok, retained} = Runtime.history(t.task_id, @caller)
    assert Enum.take(retained, length(events)) == events

    assert {:ok, _} =
             Runtime.resume(
               t.task_id,
               cp.checkpoint_id,
               "resume",
               %{"audience" => "Junior"},
               @caller
             )

    assert {:ok, %{status: :completed}} = Runtime.wait(t.task_id, @caller, 30_000)
  end

  test "T3/K09 restart after durable L1 skips L1 and rejects old attempt" do
    observer = self()

    Application.put_env(:rutvi_exercise, :step_observer, fn task, key, _output ->
      if key == {:lesson, "L1", 0} do
        send(observer, {:l1_persisted, task})

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end
      end
    end)

    on_exit(fn -> Application.delete_env(:rutvi_exercise, :step_observer) end)

    {:ok, t} =
      Runtime.start("course.create", %{"audience" => "Junior", "delay_ms" => 150}, @caller)

    assert_receive {:l1_persisted, %{task_id: task_id} = old_task}, 15_000
    assert task_id == t.task_id
    assert Store.read(&Map.has_key?(&1.tasks[t.task_id].steps, {:lesson, "L1", 0}))
    Application.delete_env(:rutvi_exercise, :step_observer)
    assert :ok = Application.stop(:rutvi_exercise)
    assert :ok = Application.start(:rutvi_exercise)
    assert {:ok, s} = Runtime.wait(t.task_id, @caller, 30_000)
    assert s.status == :completed
    assert s.run_id == t.run_id

    assert {:error, :stale_attempt} =
             RutviExercise.Runtime.Dispatcher.finish(
               old_task,
               :completed,
               %{"stale" => true},
               nil
             )

    tasks = Store.read(fn d -> Enum.filter(Map.values(d.tasks), &(&1.run_id == t.run_id)) end)

    assert Enum.count(
             tasks,
             &(&1.service_id == "course.author" and &1.input["lesson_id"] == "L1")
           ) == 1

    {:ok, events} = Runtime.history(t.task_id, @caller)

    assert Enum.count(
             events,
             &(&1.type == :step_completed and Map.get(&1, :step) == {:lesson, "L1", 0})
           ) == 1
  end

  test "T6 per-root limits remain isolated while parents wait and lessons delay 1000ms" do
    runs =
      for limit <- [1, 2] do
        {:ok, t} =
          Runtime.start("course.create", %{"audience" => "Junior", "delay_ms" => 1000}, @caller,
            concurrency_limit: limit
          )

        {t, limit}
      end

    for {t, limit} <- runs do
      assert {:ok, %{status: :completed}} = Runtime.wait(t.task_id, @caller, 30_000)
      {:ok, events} = Runtime.history(t.task_id, @caller)
      counts = for event <- events, event.type == :external_started, do: event.active_count
      assert Enum.max(counts) == limit
      assert Enum.all?(counts, &(&1 <= limit))
    end
  end

  test "K12 evaluator failure cannot affect accepted workflow output" do
    Application.put_env(:rutvi_exercise, :evaluator, Evaluator)
    on_exit(fn -> Application.delete_env(:rutvi_exercise, :evaluator) end)
    {:ok, t} = Runtime.start("course.create", %{"audience" => "Junior"}, @caller)
    assert {:ok, %{status: :completed}} = Runtime.wait(t.task_id, @caller, 30_000)
  end

  test "K09 stale failed result cannot cancel the newer running attempt; first terminal result wins" do
    id = Store.id()

    Runtime.register_service(%{
      service_id: id,
      capabilities: [id],
      namespace: "A",
      owner: "alice",
      workflow: FencedSlow
    })

    {:ok, t} = Runtime.start(id, %{}, @caller)
    Process.sleep(20)
    old = Store.read(& &1.tasks[t.task_id])

    current =
      Store.transact(fn data ->
        task = %{data.tasks[t.task_id] | status: :running, attempt: old.attempt + 1}
        {task, Runtime.put_task(data, task, :running)}
      end)

    assert {:error, :stale_attempt} =
             RutviExercise.Runtime.Dispatcher.finish(old, :failed, nil, :old_failure)

    assert {:ok, %{status: :running, attempt: attempt}} = Runtime.inspect(t.task_id, @caller)
    assert attempt == current.attempt

    assert :ok =
             RutviExercise.Runtime.Dispatcher.finish(
               current,
               :completed,
               %{"accepted" => true},
               nil
             )

    assert {:error, :stale_attempt} =
             RutviExercise.Runtime.Dispatcher.finish(current, :failed, nil, :late_failure)

    assert {:ok, %{status: :completed, result: %{"accepted" => true}}} =
             Runtime.inspect(t.task_id, @caller)
  end

  test "K07 direct and nested delegated checkpoints pause roots and resume after restart without duplicate children" do
    for depth <- [1, 2] do
      ids = for _ <- 0..depth, do: Store.id()

      for {id, index} <- Enum.with_index(ids) do
        allowed = if index < depth, do: [Enum.at(ids, index + 1)], else: []

        Runtime.register_service(%{
          service_id: id,
          capabilities: [id],
          namespace: "A",
          owner: "alice",
          workflow: HumanChain,
          allowed_services: allowed
        })
      end

      {:ok, t} = Runtime.start(hd(ids), %{"chain" => tl(ids)}, @caller)
      {:ok, s} = Runtime.wait(t.task_id, @caller, 3000)
      assert s.status in [:running, :waiting_for_children]
      assert length(s.waiting_descendants) == 1
      cp = hd(s.checkpoints)
      human = hd(s.waiting_descendants)
      assert cp.task_id == human.task_id
      assert human.depth == depth
      assert :ok = Application.stop(:rutvi_exercise)
      assert :ok = Application.start(:rutvi_exercise)
      assert {:ok, restored} = Runtime.wait(t.task_id, @caller, 3000)
      assert Enum.any?(restored.checkpoints, &(&1.checkpoint_id == cp.checkpoint_id))

      assert {:ok, _} =
               Runtime.resume(
                 t.task_id,
                 cp.checkpoint_id,
                 "answer",
                 %{"answer" => "yes"},
                 @caller
               )

      assert {:ok, %{status: :completed, result: %{"answer" => "yes"}}} =
               Runtime.wait(t.task_id, @caller, 5000)

      tasks =
        Store.read(fn data -> Enum.filter(Map.values(data.tasks), &(&1.run_id == t.run_id)) end)

      assert length(tasks) == depth + 1
      assert Enum.all?(tasks, &(&1.status == :completed))
    end
  end
end
