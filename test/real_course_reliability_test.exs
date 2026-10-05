defmodule RutviExercise.RealCourseReliabilityTest do
  use ExUnit.Case, async: false
  alias RutviExercise.{Runtime, Store}
  @caller %{namespace_id: "A", user_id: "live-regression", session_id: "local"}

  defmodule Child do
    use Synaptic.Workflow

    step :slow do
      send(Application.fetch_env!(:rutvi_exercise, :reliability_owner), {:child_started, self()})

      receive do
        :release -> {:ok, %{result: %{"value" => "complete"}}}
      after
        5_000 -> {:error, :test_timeout}
      end
    end

    commit()
  end

  defmodule Parent do
    use Synaptic.Workflow

    step :parent do
      task = context.task

      with {:ok, _} <-
             RutviExercise.Runtime.Step.run(task, :before, fn ->
               send(Application.fetch_env!(:rutvi_exercise, :reliability_owner), :durable_step)
               {:ok, %{saved: true}}
             end),
           {:ok, child} <-
             RutviExercise.Runtime.delegate(task, context.input["child"], %{}, "slow") do
        {:ok, %{result: child}}
      end
    end

    commit()
  end

  defmodule RetryAdapter do
    def generate(request, opts) do
      send(Application.fetch_env!(:rutvi_exercise, :reliability_owner), {:request, request, opts})
      value = if request.attempt == 1, do: "invalid", else: "accepted"

      {:ok,
       %{
         output: %{"value" => value},
         model: "local-test",
         reasoning_effort: "low",
         usage: %{requests: 1}
       }}
    end
  end

  defmodule CrashingAdapter do
    def generate(_request, _opts),
      do: raise("sensitive authorization header must never be logged")
  end

  defmodule ModelWorkflow do
    use Synaptic.Workflow

    step :generate do
      with {:ok, value} <-
             RutviExercise.Runtime.Model.generate(
               context.task,
               :validation,
               "schema",
               RutviExercise.Runtime.Schema.object(
                 %{"value" => RutviExercise.Runtime.Schema.string()},
                 ["value"]
               ),
               %{
                 output_validator: fn
                   %{"value" => "accepted"} -> :ok
                   _ -> {:error, "value must be accepted"}
                 end
               }
             ) do
        {:ok, %{result: value}}
      end
    end

    commit()
  end

  setup do
    Application.put_env(:rutvi_exercise, :reliability_owner, self())
    previous_adapter = Application.get_env(:rutvi_exercise, :model_adapter)
    previous_defaults = Application.get_env(:rutvi_exercise, :model_defaults)

    on_exit(fn ->
      Application.delete_env(:rutvi_exercise, :reliability_owner)
      Application.put_env(:rutvi_exercise, :model_adapter, previous_adapter)
      Application.put_env(:rutvi_exercise, :model_defaults, previous_defaults)
    end)

    :ok
  end

  defp register(id, workflow, extra \\ %{}),
    do:
      Runtime.register_service(
        Map.merge(
          %{
            service_id: id,
            capabilities: [id],
            namespace: "A",
            owner: "alice",
            workflow: workflow
          },
          extra
        )
      )

  test "pending child releases parent worker and replay reuses durable output and single child" do
    child = Store.id()
    parent = Store.id()
    register(child, Child)
    register(parent, Parent, %{allowed_services: [child]})
    {:ok, task} = Runtime.start(parent, %{"child" => child}, @caller)
    assert_receive :durable_step, 1000
    assert_receive {:child_started, worker}, 1000
    Process.sleep(200)
    {:ok, snapshot} = Runtime.inspect(task.task_id, @caller)
    assert snapshot.status == :waiting_for_children
    assert snapshot.paused_on_child == hd(snapshot.children).task_id
    refute Map.has_key?(:sys.get_state(RutviExercise.Runtime.Dispatcher), task.task_id)
    assert Process.alive?(worker)
    send(worker, :release)

    assert {:ok, %{status: :completed, result: %{"value" => "complete"}}} =
             Runtime.wait(task.task_id, @caller, 2000)

    refute_receive :durable_step, 50
    {:ok, completed} = Runtime.inspect(task.task_id, @caller)
    assert length(completed.children) == 1
    assert completed.attempt >= 2
  end

  test "semantic invalid output retries with feedback and records explicit profile and actual usage" do
    Application.put_env(:rutvi_exercise, :model_adapter, RetryAdapter)

    Application.put_env(:rutvi_exercise, :model_defaults, %{
      timeout_ms: 90_000,
      profile: "codex_local"
    })

    id = Store.id()
    register(id, ModelWorkflow, %{model_profile: %{timeout_ms: 2500}})
    {:ok, task} = Runtime.start(id, %{}, @caller)

    assert {:ok, %{status: :completed, result: %{"value" => "accepted"}}} =
             Runtime.wait(task.task_id, @caller, 2000)

    assert_receive {:request, %{attempt: 1}, first_opts}
    assert first_opts[:timeout_ms] == 2500
    assert_receive {:request, %{attempt: 2, messages: messages}, _}
    assert List.last(messages).content =~ "previous response failed local validation"
    {:ok, events} = Runtime.history(task.task_id, @caller)
    [invalid, accepted] = Enum.filter(events, &(&1.type == :model_response))

    assert invalid.outcome == %{
             status: :error,
             error: %{code: :invalid_output, retryable: true, details: "value must be accepted"}
           }

    assert invalid.validation_error == "value must be accepted"
    assert accepted.settings.profile == "codex_local"
    assert accepted.settings.timeout_ms == 2500
    assert accepted.usage == %{requests: 1}
    assert accepted.reasoning_effort == "low"
  end

  test "provider exceptions are redacted, fail once and are distinct from genuine timeouts" do
    Application.put_env(:rutvi_exercise, :model_adapter, CrashingAdapter)
    id = Store.id()
    register(id, ModelWorkflow)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, task} = Runtime.start(id, %{}, @caller)

        assert {:ok, %{status: :failed, error: %{code: :provider_exception, retryable: false}}} =
                 Runtime.wait(task.task_id, @caller, 2000)

        {:ok, events} = Runtime.history(task.task_id, @caller)
        assert length(Enum.filter(events, &(&1.type == :provider_reserved))) == 1

        refute Enum.any?(
                 events,
                 &(&1.type == :model_response and &1.outcome[:error][:code] == :timeout)
               )
      end)

    refute log =~ "sensitive authorization"
    assert {:ok, applications} = :application.get_key(:rutvi_exercise, :applications)
    assert :inets in applications
    assert :ssl in applications
    assert Code.ensure_loaded?(:httpc)
  end

  test "course rejects duplicate objectives and questions, incorrect exact passages and short real author output" do
    sources = RutviExercise.Course.Sources.all()
    assert :ok = RutviExercise.Course.validate("course.research", %{"passages" => sources}, %{})

    assert {:error, _} =
             RutviExercise.Course.validate(
               "course.research",
               %{"passages" => [hd(sources) | sources]},
               %{}
             )

    Application.put_env(:rutvi_exercise, :model_adapter, RetryAdapter)

    lesson = %{
      "questions" => [%{"id" => "Q1", "objective_id" => "O1"}],
      "lesson" => %{"id" => "L1", "objective_id" => "O1", "text" => "Short."}
    }

    assert {:error, _} =
             RutviExercise.Course.validate("course.author", lesson, %{"lesson_id" => "L1"})

    valid = put_in(lesson, ["lesson", "text"], Enum.join(List.duplicate("slovo", 150), " "))
    assert :ok = RutviExercise.Course.validate("course.author", valid, %{"lesson_id" => "L1"})

    invalid_quiz = put_in(valid, ["questions"], [%{"id" => "Q2", "objective_id" => "O2"}])

    assert {:error, _} =
             RutviExercise.Course.validate("course.author", invalid_quiz, %{"lesson_id" => "L1"})

    plan = %{
      "objectives" => [%{"id" => "O1"}, %{"id" => "O1"}],
      "outline" => [
        %{"lesson_id" => "L1", "objective_id" => "O1"},
        %{"lesson_id" => "L2", "objective_id" => "O2"}
      ],
      "questions" => Enum.map(["Q1", "Q2", "Q3"], &%{"id" => &1})
    }

    assert {:error, _} = RutviExercise.Course.validate("course.plan", plan, %{})
  end
end
