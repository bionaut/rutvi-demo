defmodule RutviExercise.ModelProtocolTest do
  use ExUnit.Case, async: false
  alias RutviExercise.{Runtime, Store, Runtime.Schema}
  @caller %{namespace_id: "A", user_id: "alice", session_id: "model"}
  defmodule Adapter do
    def generate(request, opts) do
      input = Jason.decode!(Enum.at(request.messages, 1).content)

      if pid = Application.get_env(:rutvi_exercise, :protocol_observer),
        do: send(pid, {:request, request, opts})

      case input["scenario"] do
        "retry" ->
          case request.attempt do
            1 ->
              {:error, %{code: :timeout, retryable: true}}

            2 ->
              {:ok, %{output: %{"summary" => 42}}}

            3 ->
              {:ok, %{output: %{"summary" => "accepted", "citations" => []}, model: opts[:model]}}
          end

        "fail" ->
          {:error, %{code: :timeout, retryable: true}}

        "budget" ->
          if request.attempt < 3 do
            {:error, %{code: :timeout, retryable: true}}
          else
            {:ok,
             %{
               tool_calls: [
                 %{
                   call_id: "c#{request.turn}",
                   name: "read_passage",
                   arguments: %{"source_id" => "S2", "passage_id" => "P1"}
                 }
               ]
             }}
          end

        "loop" ->
          {:ok,
           %{
             tool_calls: [
               %{
                 call_id: "c#{request.turn}",
                 name: "read_passage",
                 arguments: %{"source_id" => "S2", "passage_id" => "P1"}
               }
             ]
           }}

        "tools" when request.turn == 0 ->
          {:ok,
           %{
             tool_calls: [
               %{
                 call_id: "s2",
                 name: "read_passage",
                 arguments: %{"source_id" => "S2", "passage_id" => "P1"}
               },
               %{
                 call_id: "s3",
                 name: "read_passage",
                 arguments: %{"source_id" => "S3", "passage_id" => "P1"}
               },
               %{
                 call_id: "invalid",
                 name: "read_passage",
                 arguments: %{"source_id" => 42, "passage_id" => "P1"}
               },
               %{call_id: "unknown", name: "bad", arguments: %{}},
               %{call_id: "forbidden", name: "secret", arguments: %{}}
             ]
           }}

        "tools" ->
          {:ok,
           %{
             output: %{
               "summary" => "accepted",
               "citations" => [%{"source_id" => "S2", "passage_id" => "P1"}]
             },
             model: opts[:model]
           }}
      end
    end
  end

  defmodule Workflow do
    use Synaptic.Workflow

    step :model do
      schema =
        RutviExercise.Runtime.Schema.object(
          %{
            "summary" => RutviExercise.Runtime.Schema.string(),
            "citations" => %{
              "type" => "array",
              "items" =>
                RutviExercise.Runtime.Schema.object(
                  %{
                    "source_id" => RutviExercise.Runtime.Schema.string(),
                    "passage_id" => RutviExercise.Runtime.Schema.string()
                  },
                  ["source_id", "passage_id"]
                )
            }
          },
          ["summary", "citations"]
        )

      RutviExercise.Runtime.Step.run(context.task, :model, fn ->
        with {:ok, output} <-
               RutviExercise.Runtime.Model.generate(
                 context.task,
                 :interaction,
                 "protocol",
                 schema
               ),
             do: {:ok, %{result: output}}
      end)
    end

    commit()
  end

  setup do
    old = Application.get_env(:rutvi_exercise, :model_adapter)
    Application.put_env(:rutvi_exercise, :model_adapter, Adapter)
    Application.put_env(:rutvi_exercise, :protocol_observer, self())

    on_exit(fn ->
      Application.put_env(:rutvi_exercise, :model_adapter, old)
      Application.delete_env(:rutvi_exercise, :protocol_observer)
    end)

    id = Store.id()

    {:ok, _} =
      Runtime.register_service(%{
        service_id: id,
        capabilities: [id],
        namespace: "A",
        owner: "alice",
        workflow: Workflow,
        allowed_tools: ["read_passage", "bad"],
        model_profile: %{model: "profile-model"},
        allowed_model_overrides: [:model],
        input_schema: Schema.object(%{"scenario" => Schema.string()}, ["scenario"])
      })

    %{service: id}
  end

  test "T4 timeout and invalid JSON retry up to three requests; three timeouts fail", %{
    service: id
  } do
    {:ok, t} = Runtime.start(id, %{"scenario" => "retry"}, @caller)
    assert {:ok, %{status: :completed}} = Runtime.wait(t.task_id, @caller, 3000)
    {:ok, events} = Runtime.history(t.task_id, @caller)

    assert Enum.filter(events, &(&1.type == :provider_reserved)) |> Enum.map(& &1.attempt) == [
             1,
             2,
             3
           ]

    {:ok, t} = Runtime.start(id, %{"scenario" => "fail"}, @caller)
    assert {:ok, %{status: :failed}} = Runtime.wait(t.task_id, @caller, 3000)
    {:ok, events} = Runtime.history(t.task_id, @caller)
    assert Enum.count(events, &(&1.type == :provider_reserved)) == 3
  end

  test "K10 validates multi-call tools, preserves IDs/texts and uses allowed override", %{
    service: id
  } do
    {:ok, t} =
      Runtime.start(id, %{"scenario" => "tools"}, @caller,
        model_override: %{model: "override", namespace_id: "forged"}
      )

    assert {:ok, %{status: :completed}} = Runtime.wait(t.task_id, @caller, 3000)
    assert_receive {:request, %{turn: 0}, opts}
    assert opts[:model] == "override"
    assert_receive {:request, %{turn: 1, tool_results: results}, _}
    by_id = Map.new(results, &{&1.call_id, &1.result})
    assert by_id["s2"] == RutviExercise.Course.Sources.read("S2", "P1")
    assert by_id["s3"] == RutviExercise.Course.Sources.read("S3", "P1")
    assert by_id["invalid"] == {:error, :validation_error}
    assert by_id["unknown"] == {:error, :not_found}
    assert by_id["forbidden"] == {:error, :forbidden}
    assert {:error, :validation_error} = Runtime.start(id, %{"scenario" => 42}, @caller)
  end

  test "K10 fifth tool round stops before any handler", %{service: id} do
    {:ok, t} = Runtime.start(id, %{"scenario" => "loop"}, @caller)
    assert {:ok, %{status: :failed}} = Runtime.wait(t.task_id, @caller, 3000)
    steps = Store.read(& &1.tasks[t.task_id].steps)
    tool_keys = Enum.filter(Map.keys(steps), &match?({:tool, _, _, _}, &1))
    assert length(tool_keys) == 4
    {:ok, events} = Runtime.history(t.task_id, @caller)
    assert Enum.count(events, &(&1.type == :provider_reserved)) == 5
  end

  test "K09 restart after second consumed provider attempt resumes on third", %{service: id} do
    observer = self()

    Application.put_env(:rutvi_exercise, :model_observer, fn task,
                                                             _interaction,
                                                             _turn,
                                                             attempt,
                                                             _output ->
      if attempt == 2 do
        send(observer, {:second_attempt_committed, task, self()})

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end
      end
    end)

    on_exit(fn -> Application.delete_env(:rutvi_exercise, :model_observer) end)
    {:ok, t} = Runtime.start(id, %{"scenario" => "retry"}, @caller)
    assert_receive {:second_attempt_committed, old_task, old_pid}, 2000
    assert Store.read(& &1.counters[{:attempts, t.task_id, :interaction, 0}]) == 2
    Application.delete_env(:rutvi_exercise, :model_observer)
    assert :ok = Application.stop(:rutvi_exercise)
    assert :ok = Application.start(:rutvi_exercise)
    assert {:ok, %{status: :completed}} = Runtime.wait(t.task_id, @caller, 3000)
    send(old_pid, :release)

    assert {:error, :stale_attempt} =
             RutviExercise.Runtime.Dispatcher.finish(old_task, :completed, %{"old" => true}, nil)

    {:ok, events} = Runtime.history(t.task_id, @caller)

    assert Enum.filter(events, &(&1.type == :provider_reserved)) |> Enum.map(& &1.attempt) == [
             1,
             2,
             3
           ]
  end

  test "K10 durable interaction budget permits at most fifteen provider requests", %{service: id} do
    {:ok, t} = Runtime.start(id, %{"scenario" => "budget"}, @caller)
    assert {:ok, %{status: :failed}} = Runtime.wait(t.task_id, @caller, 4000)
    assert Store.read(& &1.counters[{:requests, t.task_id, :interaction}]) == 15
    {:ok, events} = Runtime.history(t.task_id, @caller)
    assert Enum.count(events, &(&1.type == :provider_reserved)) == 15
    task = Store.read(& &1.tasks[t.task_id])

    assert {:error, :stale_attempt} =
             RutviExercise.Runtime.Model.generate(task, :interaction, "budget", %{
               "type" => "object"
             })

    assert Store.read(& &1.counters[{:requests, t.task_id, :interaction}]) == 15
  end
end
