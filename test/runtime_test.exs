defmodule RutviExercise.RuntimeTest do
  use ExUnit.Case, async: false
  alias RutviExercise.{Runtime, Store}
  @a %{namespace_id: "A", user_id: "alice", session_id: "session"}
  @other %{namespace_id: "A", user_id: "bob", session_id: "session"}
  defmodule Slow do
    use Synaptic.Workflow

    step :slow do
      Process.sleep(2000)
      {:ok, %{result: context.input}}
    end

    commit()
  end

  def service(id, opts \\ %{}) do
    Map.merge(
      %{
        service_id: id,
        capabilities: [id],
        namespace: "A",
        owner: "alice",
        workflow: Slow,
        input_schema: %{"type" => "object"},
        output_schema: %{"type" => "object"}
      },
      opts
    )
  end

  def unique, do: Store.id()
  def finish(t), do: Runtime.wait(t.task_id, @a, 30_000)

  test "K01 echo registration is generic and identical definitions succeed" do
    id = unique()
    s = service(id, %{workflow: RutviExercise.Workflows.Echo})
    assert {:ok, _} = Runtime.register_service(s)
    assert {:ok, _} = Runtime.register_service(s)
    assert {:error, :conflict} = Runtime.register_service(%{s | workflow: Slow})
    assert {:ok, t} = Runtime.start(id, %{"message" => "echo"}, @a)
    assert {:ok, %{status: :completed, result: %{"message" => "echo"}}} = finish(t)
  end

  test "K02 capabilities are ambiguous only within authorized scope; IDs cannot bypass ownership" do
    cap = unique()
    a = service(unique(), %{capabilities: [cap]})
    b = service(unique(), %{capabilities: [cap]})
    c = service(unique(), %{capabilities: [cap], namespace: "B"})
    Enum.each([a, b, c], &Runtime.register_service/1)
    assert {:error, :ambiguous_target} = Runtime.start(%{capability: cap}, %{}, @a)
    assert {:error, :not_found} = Runtime.start("absent", %{}, @a)
    assert {:error, :forbidden} = Runtime.start(c.service_id, %{}, @a)
    assert {:ok, t} = Runtime.start(a.service_id, %{}, @a)
    assert {:error, :forbidden} = Runtime.inspect(t.task_id, @other)
    assert {:error, :forbidden} = Runtime.history(t.task_id, @other)
    assert {:error, :forbidden} = Runtime.cancel(t.task_id, @other)
    Process.sleep(30)
    {:ok, owned} = Runtime.inspect(t.task_id, @a)
    assert owned.status != :cancelled
    assert owned.attempt <= 1
    assert {:ok, _} = Runtime.cancel(t.task_id, @a)
  end

  test "T2 atomically deduplicates concurrent starts and rejects changed input" do
    key = unique()

    handles =
      1..12
      |> Task.async_stream(
        fn _ ->
          Runtime.start("course.create", %{"audience" => "Junior"}, @a, idempotency_key: key)
        end,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, {:ok, t}} -> t end)

    assert handles |> Enum.map(& &1.task_id) |> Enum.uniq() |> length() == 1
    t = hd(handles)
    assert {:ok, %{status: :completed}} = finish(t)

    assert {:ok, %{task_id: id}} =
             Runtime.start("course.create", %{"audience" => "Junior"}, @a, idempotency_key: key)

    assert id == t.task_id

    assert {:error, :conflict} =
             Runtime.start("course.create", %{"audience" => "Senior"}, @a, idempotency_key: key)
  end

  test "K03 references resolve by alias with explicit latest and active_only" do
    id = unique()
    alias_name = unique()
    Runtime.register_service(service(id))
    {:ok, a} = Runtime.start(id, %{}, @a, aliases: [alias_name], purpose: "proof")
    {:ok, b} = Runtime.start(id, %{}, @a, aliases: [alias_name], purpose: "proof")
    assert {:error, :ambiguous_reference} = Runtime.resolve(%{alias: alias_name}, @a)
    assert {:ok, %{task_id: latest}} = Runtime.resolve(%{alias: alias_name, latest: true}, @a)
    assert latest == b.task_id
    Runtime.cancel(a.task_id, @a)
    Runtime.cancel(b.task_id, @a)
    assert {:error, :not_found} = Runtime.resolve(%{alias: alias_name, active_only: true}, @a)
    assert {:ok, _} = Runtime.resolve(%{alias: alias_name, latest: true}, @a)
  end

  test "K04 session reuse is atomic and isolated from sessions, payloads, and completed tasks" do
    id = unique()
    Runtime.register_service(service(id, %{lifecycle: :session}))
    {:ok, a} = Runtime.start(id, %{"x" => 1}, @a, reuse_key: "r", purpose: "p")
    {:ok, b} = Runtime.start(id, %{"x" => 1}, @a, reuse_key: "r", purpose: "p")
    assert a.task_id == b.task_id
    assert {:error, :conflict} = Runtime.start(id, %{"x" => 2}, @a, reuse_key: "r", purpose: "p")

    {:ok, c} =
      Runtime.start(id, %{"x" => 1}, %{@a | session_id: "different"},
        reuse_key: "r",
        purpose: "p"
      )

    assert c.task_id != a.task_id
    Runtime.cancel(a.task_id, @a)
    Runtime.cancel(c.task_id, @a)
    {:ok, d} = Runtime.start(id, %{"x" => 1}, @a, reuse_key: "r", purpose: "p")
    assert d.task_id != a.task_id
    Runtime.cancel(d.task_id, @a)
  end

  test "K07 audience validation, durable checkpoint consumption and second checkpoint" do
    {:ok, t} = Runtime.start("course.create", %{"ask_style" => true}, @a)
    {:ok, s} = finish(t)
    assert s.status == :waiting_for_children
    cp = hd(s.checkpoints)

    assert {:error, :validation_error} =
             Runtime.resume(t.task_id, cp.checkpoint_id, "r", %{"audience" => 42}, @a)

    assert {:error, :forbidden} =
             Runtime.resume(t.task_id, cp.checkpoint_id, "r", %{"audience" => "Junior"}, @other)

    assert {:ok, _} =
             Runtime.resume(t.task_id, cp.checkpoint_id, "r", %{"audience" => "Junior"}, @a)

    Process.sleep(30)
    {:ok, s} = finish(t)
    assert length(s.checkpoints) == 2

    assert {:ok, _} =
             Runtime.resume(t.task_id, cp.checkpoint_id, "r", %{"audience" => "Junior"}, @a)

    assert {:error, :conflict} =
             Runtime.resume(t.task_id, cp.checkpoint_id, "r2", %{"audience" => "Other"}, @a)

    new = List.last(s.checkpoints)
    assert new.checkpoint_id != cp.checkpoint_id

    assert {:ok, _} =
             Runtime.resume(t.task_id, new.checkpoint_id, "style", %{"style" => "practical"}, @a)

    assert {:ok, %{status: :completed}} = finish(t)
  end

  test "K08 inspect and bounded wait remain responsive; repeated cancellation fences late work" do
    id = unique()
    Runtime.register_service(service(id))
    {:ok, t} = Runtime.start(id, %{}, @a)
    start = System.monotonic_time(:millisecond)
    assert {:ok, _} = Runtime.wait(t.task_id, @a, 0)
    assert {:ok, _} = Runtime.inspect(t.task_id, @a)
    assert System.monotonic_time(:millisecond) - start < 500
    start = System.monotonic_time(:millisecond)
    assert {:ok, _} = Runtime.wait(t.task_id, @a, 100)
    assert System.monotonic_time(:millisecond) - start < 500
    assert {:ok, %{status: :cancelled}} = Runtime.cancel(t.task_id, @a)
    assert {:ok, %{status: :cancelled}} = Runtime.cancel(t.task_id, @a)
    Process.sleep(20)
    assert {:ok, %{status: :cancelled, result: nil}} = Runtime.inspect(t.task_id, @a)
  end

  test "T1 course uses four roles and only L2 is revised; author delegates with inherited identity" do
    {:ok, t} = Runtime.start("course.create", %{"audience" => "Juniorní backendoví vývojáři"}, @a)
    {:ok, s} = finish(t)
    assert s.status == :completed
    assert length(s.result["questions"]) == 3
    assert Enum.map(s.result["lessons"], &{&1["id"], &1["revision"]}) == [{"L1", 0}, {"L2", 1}]
    tasks = Store.read(fn d -> Enum.filter(Map.values(d.tasks), &(&1.run_id == t.run_id)) end)

    assert Enum.count(
             tasks,
             &(&1.service_id == "course.author" and &1.input["lesson_id"] == "L1")
           ) == 1

    research = Enum.filter(tasks, &(&1.service_id == "course.research" and &1.depth == 2))
    assert length(research) == 3
    assert Enum.all?(tasks, &(&1.user_id == @a.user_id and &1.request_id == t.request_id))
    assert Enum.all?(research, &(&1.delegation_reason != nil and &1.parent_id != nil))
  end

  test "T5 reviewer always refusing permits two content revisions then needs_review" do
    {:ok, t} =
      Runtime.start("course.create", %{"audience" => "Junior", "always_revise" => true}, @a)

    {:ok, s} = finish(t)
    assert s.status == :needs_review
    assert s.revision == 2
    assert s.error == :revision_limit
    assert length(s.result["lessons"]) == 2
  end

  test "K12 cursor history retains event identity and monotonic run sequence" do
    {:ok, t} = Runtime.start("course.create", %{"audience" => "Junior"}, @a)
    {:ok, %{status: :completed}} = finish(t)
    {:ok, all} = Runtime.history(t.task_id, @a)
    seq = Enum.map(all, & &1.sequence)
    assert seq == Enum.to_list(1..length(all))
    cursor = div(length(all), 2)
    assert {:ok, tail} = Runtime.history(t.task_id, @a, cursor)
    assert tail == Enum.drop(all, cursor)
    assert length(Enum.uniq_by(all, & &1.event_id)) == length(all)
  end
end
