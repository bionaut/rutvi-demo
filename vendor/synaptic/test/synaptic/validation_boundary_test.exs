defmodule Synaptic.ValidationBoundaryTest do
  use ExUnit.Case

  defmodule StartInputWorkflow do
    use Synaptic.Workflow

    step :greet,
      input: %{name: :string},
      output: %{greeting: :string},
      validation: [input: :subset, output: :strict] do
      name = Map.get(context, :name) || Map.get(context, "name")
      {:ok, %{greeting: "hello #{name}"}}
    end

    commit()
  end

  defmodule StartAtWorkflow do
    use Synaptic.Workflow

    step :first do
      {:ok, %{first: true}}
    end

    step :second,
      input: %{token: :string},
      output: %{processed: :boolean},
      validation: [input: :subset, output: :strict] do
      {:ok, %{processed: true}}
    end

    commit()
  end

  defmodule ResumeWorkflow do
    use Synaptic.Workflow

    step :review,
      suspend: true,
      resume_schema: %{approved: :boolean},
      validation: [resume: :strict] do
      approved =
        get_in(context, [:human_input, :approved]) ||
          get_in(context, [:human_input, "approved"])

      case approved do
        nil -> suspend_for_human("Approve?")
        approved -> {:ok, %{approved: approved}}
      end
    end

    commit()
  end

  defmodule StepInputSubsetWorkflow do
    use Synaptic.Workflow

    step :prepare, output: %{required: :string, extra: :string} do
      {:ok, %{required: "ready", extra: "keep"}}
    end

    step :consume,
      input: %{required: :string},
      output: %{done: :boolean},
      validation: [input: :subset, output: :strict] do
      send(context.test_pid, {:consume, context.required, context.extra})
      {:ok, %{done: true}}
    end

    commit()
  end

  defmodule SequentialInputValidationWorkflow do
    use Synaptic.Workflow

    step :prepare do
      {:ok, %{}}
    end

    step :needs_input, input: %{required: :string}, retry: 2, validation: [input: :subset] do
      send(context.test_pid, :should_not_run)
      {:ok, %{done: true}}
    end

    commit()
  end

  defmodule ParallelInputValidationWorkflow do
    use Synaptic.Workflow

    step :prepare do
      {:ok, %{}}
    end

    parallel_step :fan_out, input: %{required: :string}, retry: 1, validation: [input: :subset] do
      [
        fn ctx ->
          send(ctx.test_pid, :parallel_task_started)
          {:ok, %{done: true}}
        end
      ]
    end

    commit()
  end

  defmodule AsyncInputValidationWorkflow do
    use Synaptic.Workflow

    step :prepare do
      {:ok, %{}}
    end

    async_step :notify, input: %{required: :string}, retry: 1, validation: [input: :subset] do
      send(context.test_pid, :async_started)
      {:ok, %{sent: true}}
    end

    step :after do
      send(context.test_pid, :after_should_not_run)
      {:ok, %{after: true}}
    end

    commit()
  end

  defmodule StrictOutputWorkflow do
    use Synaptic.Workflow

    step :produce, output: %{allowed: :boolean}, validation: [output: :strict] do
      {:ok, %{allowed: true, extra: "boom"}}
    end

    commit()
  end

  defmodule DefaultValidationOffWorkflow do
    use Synaptic.Workflow

    step :greet, input: %{name: :string}, output: %{greeting: :string} do
      {:ok,
       %{
         greeting: "hello #{inspect(Map.get(context, :name) || Map.get(context, "name"))}",
         extra: true
       }}
    end

    commit()
  end

  defmodule ResumeValidationOffWorkflow do
    use Synaptic.Workflow

    step :review,
      suspend: true,
      resume_schema: %{approved: :boolean},
      validation: [resume: :off] do
      payload = Map.get(context, :human_input, %{})

      case payload do
        %{} = payload when map_size(payload) == 0 ->
          suspend_for_human("Approve?")

        _ ->
          {:ok, %{approved: Map.get(payload, :approved) || Map.get(payload, "approved")}}
      end
    end

    commit()
  end

  defmodule SubsetOutputWorkflow do
    use Synaptic.Workflow

    step :produce, output: %{allowed: :boolean}, validation: [output: :subset] do
      {:ok, %{allowed: true, extra: "boom"}}
    end

    commit()
  end

  defmodule OutputValidationOffWorkflow do
    use Synaptic.Workflow

    step :produce, output: %{allowed: :boolean}, validation: [output: :off] do
      {:ok, %{extra: "boom"}}
    end

    commit()
  end

  defmodule ConstrainedInputWorkflow do
    use Synaptic.Workflow

    step :capture,
      input: %{
        role: [type: :string, enum: ["admin", "member"]],
        email: [type: :string, regex: ~r/^[^\s]+@[^\s]+\.[^\s]+$/],
        age: [type: :integer, min: 18, max: 99],
        nickname: [type: :string, min_length: 2, max_length: 10, required: false],
        profile: [type: :map, required: false, fields: %{type: :string}]
      },
      output: %{accepted: :boolean},
      validation: [input: :strict, output: :strict] do
      {:ok, %{accepted: true}}
    end

    commit()
  end

  defmodule CanonicalizedInputWorkflow do
    use Synaptic.Workflow

    step :capture,
      input: %{
        email: [type: :string, regex: ~r/^[^\s]+@[^\s]+\.[^\s]+$/],
        accent: [type: :string, enum: ["é"]]
      },
      output: %{accepted: :boolean},
      validation: [input: :strict, output: :strict] do
      {:ok, %{accepted: true}}
    end

    commit()
  end

  defmodule ConstrainedOutputWorkflow do
    use Synaptic.Workflow

    step :produce,
      output: %{status: [type: :string, enum: ["ok"]]},
      validation: [output: :strict] do
      {:ok, %{status: "bad"}}
    end

    commit()
  end

  test "workflow input validation rejects invalid first-step input" do
    assert {:error,
            {:validation_failed,
             %{
               surface: :workflow_input,
               step: :greet,
               issues: [
                 %{
                   code: :type_mismatch,
                   path: "#/name",
                   message: "Type mismatch. Expected String but got Integer."
                 }
               ]
             }}} = Synaptic.start(StartInputWorkflow, %{name: 123})
  end

  test "workflow input validation uses the target step when starting mid-workflow" do
    assert {:error,
            {:validation_failed,
             %{
               surface: :workflow_input,
               step: :second,
               issues: [
                 %{
                   code: :type_mismatch,
                   path: "#/token",
                   message: "Type mismatch. Expected String but got Integer."
                 }
               ]
             }}} = Synaptic.start(StartAtWorkflow, %{token: 123}, start_at_step: :second)
  end

  test "workflow input validation is off by default" do
    assert {:ok, run_id} = Synaptic.start(DefaultValidationOffWorkflow, %{name: 123})

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:greeting] == "hello 123"
    assert snapshot.context[:extra] == true
  end

  test "workflow input validation accepts string keys and extra fields by default" do
    assert {:ok, run_id} =
             Synaptic.start(StartInputWorkflow, %{"name" => "Ada", "extra" => "kept"})

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:greeting] == "hello Ada"
    assert snapshot.context["extra"] == "kept"
  end

  test "step input default subset mode allows extra accumulated context" do
    parent = self()
    {:ok, run_id} = Synaptic.start(StepInputSubsetWorkflow, %{test_pid: parent})

    assert_receive {:consume, "ready", "keep"}, 500

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:done] == true
  end

  test "resume payload validation accepts string keys" do
    {:ok, run_id} = Synaptic.start(ResumeWorkflow, %{})
    assert %{status: :waiting_for_human} = wait_for(run_id, :waiting_for_human)

    assert :ok = Synaptic.resume(run_id, %{"approved" => true})

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:approved] == true
  end

  test "resume payload validation is strict about missing, mistyped, and extra fields" do
    {:ok, run_id} = Synaptic.start(ResumeWorkflow, %{})
    assert %{status: :waiting_for_human} = wait_for(run_id, :waiting_for_human)

    assert {:error,
            {:validation_failed,
             %{
               surface: :resume_payload,
               step: :review,
               issues: [
                 %{
                   code: :missing_required,
                   path: "#/approved",
                   message: "Required field \"approved\" was not present."
                 }
               ]
             }}} = Synaptic.resume(run_id, %{})

    assert {:error,
            {:validation_failed,
             %{
               surface: :resume_payload,
               step: :review,
               issues: [
                 %{
                   code: :type_mismatch,
                   path: "#/approved",
                   message: "Type mismatch. Expected Boolean but got String."
                 }
               ]
             }}} = Synaptic.resume(run_id, %{approved: "yes"})

    assert {:error,
            {:validation_failed,
             %{
               surface: :resume_payload,
               step: :review,
               issues: [
                 %{
                   code: :unexpected_field,
                   path: "#/comment",
                   message: "Unexpected field \"comment\"."
                 }
               ]
             }}} = Synaptic.resume(run_id, %{approved: true, comment: "ship it"})
  end

  test "resume payload validation can be explicitly disabled" do
    {:ok, run_id} = Synaptic.start(ResumeValidationOffWorkflow, %{})
    assert %{status: :waiting_for_human} = wait_for(run_id, :waiting_for_human)

    assert :ok = Synaptic.resume(run_id, %{approved: "yes", comment: "extra"})

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:approved] == "yes"
  end

  test "sequential step input validation fails before execution and does not retry" do
    parent = self()
    {:ok, run_id} = Synaptic.start(SequentialInputValidationWorkflow, %{test_pid: parent})

    snapshot = wait_for(run_id, :failed)

    assert snapshot.last_error ==
             {:validation_failed,
              %{
                surface: :step_input,
                step: :needs_input,
                issues: [
                  %{
                    code: :missing_required,
                    path: "#/required",
                    message: "Required field \"required\" was not present."
                  }
                ]
              }}

    assert snapshot.retries[:needs_input] == 2
    refute_receive :should_not_run, 100

    history = Synaptic.history(run_id)
    refute Enum.any?(history, &(&1[:event] == :retrying))
  end

  test "parallel step input validation fails before spawning tasks" do
    parent = self()
    {:ok, run_id} = Synaptic.start(ParallelInputValidationWorkflow, %{test_pid: parent})

    snapshot = wait_for(run_id, :failed)

    assert snapshot.last_error ==
             {:validation_failed,
              %{
                surface: :step_input,
                step: :fan_out,
                issues: [
                  %{
                    code: :missing_required,
                    path: "#/required",
                    message: "Required field \"required\" was not present."
                  }
                ]
              }}

    refute_receive :parallel_task_started, 100
  end

  test "async step input validation fails before launch and stops later steps" do
    parent = self()
    {:ok, run_id} = Synaptic.start(AsyncInputValidationWorkflow, %{test_pid: parent})

    snapshot = wait_for(run_id, :failed)

    assert snapshot.last_error ==
             {:validation_failed,
              %{
                surface: :step_input,
                step: :notify,
                issues: [
                  %{
                    code: :missing_required,
                    path: "#/required",
                    message: "Required field \"required\" was not present."
                  }
                ]
              }}

    refute_receive :async_started, 100
    refute_receive :after_should_not_run, 100
  end

  test "step output validation is off by default" do
    {:ok, run_id} = Synaptic.start(DefaultValidationOffWorkflow, %{name: 123})
    snapshot = wait_for(run_id, :completed)

    assert snapshot.context[:greeting] == "hello 123"
    assert snapshot.context[:extra] == true
  end

  test "step output validation can be opt-in strict" do
    {:ok, run_id} = Synaptic.start(StrictOutputWorkflow, %{})
    snapshot = wait_for(run_id, :failed)

    assert snapshot.last_error ==
             {:validation_failed,
              %{
                surface: :step_output,
                step: :produce,
                issues: [
                  %{
                    code: :unexpected_field,
                    path: "#/extra",
                    message: "Unexpected field \"extra\"."
                  }
                ]
              }}
  end

  test "step output validation can be relaxed to subset mode" do
    {:ok, run_id} = Synaptic.start(SubsetOutputWorkflow, %{})
    snapshot = wait_for(run_id, :completed)

    assert snapshot.context[:allowed] == true
    assert snapshot.context[:extra] == "boom"
  end

  test "step output validation can be disabled" do
    {:ok, run_id} = Synaptic.start(OutputValidationOffWorkflow, %{})
    snapshot = wait_for(run_id, :completed)

    assert snapshot.context[:extra] == "boom"
    refute Map.has_key?(snapshot.context, :allowed)
  end

  test "workflow input supports field-level constraints and optional fields" do
    assert {:ok, run_id} =
             Synaptic.start(ConstrainedInputWorkflow, %{
               role: "member",
               email: "ada@example.com",
               age: 22
             })

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:accepted] == true
  end

  test "workflow input rejects enum, regex, length, and numeric bound violations" do
    assert {:error,
            {:validation_failed,
             %{
               surface: :workflow_input,
               step: :capture,
               issues: issues
             }}} =
             Synaptic.start(ConstrainedInputWorkflow, %{
               role: "owner",
               email: "not-an-email",
               age: 12,
               nickname: "x"
             })

    assert issues == [
             %{
               code: :type_mismatch,
               path: "#/age",
               message: "Value must be at least 18."
             },
             %{
               code: :type_mismatch,
               path: "#/email",
               message: "Value did not match the required format."
             },
             %{
               code: :type_mismatch,
               path: "#/nickname",
               message: "Value must be at least 2 characters long."
             },
             %{
               code: :type_mismatch,
               path: "#/role",
               message: "Value must be one of [\"admin\", \"member\"]."
             }
           ]
  end

  test "validation canonicalizes trimmed and unicode-equivalent values before matching rules" do
    accent = "e\u0301"

    assert {:ok, run_id} =
             Synaptic.start(CanonicalizedInputWorkflow, %{
               email: "  ada@example.com  ",
               accent: accent
             })

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:accepted] == true
  end

  test "step output constraints apply to descriptor-based contracts too" do
    {:ok, run_id} = Synaptic.start(ConstrainedOutputWorkflow, %{})
    snapshot = wait_for(run_id, :failed)

    assert snapshot.last_error ==
             {:validation_failed,
              %{
                surface: :step_output,
                step: :produce,
                issues: [
                  %{
                    code: :type_mismatch,
                    path: "#/status",
                    message: "Value must be one of [\"ok\"]."
                  }
                ]
              }}
  end

  defp wait_for(run_id, status, attempts \\ 40)
  defp wait_for(_run_id, _status, 0), do: flunk("workflow did not reach desired status")

  defp wait_for(run_id, status, attempts) do
    snapshot = Synaptic.inspect(run_id)

    if snapshot.status == status do
      snapshot
    else
      Process.sleep(25)
      wait_for(run_id, status, attempts - 1)
    end
  end
end
