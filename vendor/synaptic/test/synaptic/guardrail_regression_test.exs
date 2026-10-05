defmodule Synaptic.GuardrailRegressionTest do
  use ExUnit.Case

  alias Synaptic.TestSupport.AdversarialFixtures

  defmodule CaptureAdapter do
    def chat(messages, _opts) do
      Process.put({__MODULE__, :last_messages}, messages)
      Process.get({__MODULE__, :result}, {:ok, "ok"})
    end
  end

  defmodule ToolLoopAdapter do
    def chat(messages, _opts) do
      case Process.get({__MODULE__, :stage}, :first) do
        :first ->
          Process.put({__MODULE__, :stage}, :second)

          {:ok,
           %{
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "function" => %{
                   "name" => "send_email",
                   "arguments" => ~s({"email":"jane@example.com"})
                 }
               }
             ]
           }}

        :second ->
          Process.put(:last_tool_message, List.last(messages))
          {:ok, "final"}
      end
    end
  end

  defmodule ValidationWorkflow do
    use Synaptic.Workflow

    step :start,
      input: %{email: [type: :string, regex: ~r/^[^\s]+@[^\s]+$/]},
      validation: [input: :strict] do
      {:ok, %{done: true}}
    end

    commit()
  end

  setup do
    handler_prefix = "guardrail-regression-#{System.unique_integer([:positive])}"

    attach("#{handler_prefix}-prompt", [:synaptic, :prompt_security, :detection])
    attach("#{handler_prefix}-policy", [:synaptic, :security_policy, :decision])
    attach("#{handler_prefix}-factuality", [:synaptic, :factuality, :check])
    attach("#{handler_prefix}-actions", [:synaptic, :action_controls, :dispatch])

    on_exit(fn ->
      :telemetry.detach("#{handler_prefix}-prompt")
      :telemetry.detach("#{handler_prefix}-policy")
      :telemetry.detach("#{handler_prefix}-factuality")
      :telemetry.detach("#{handler_prefix}-actions")
      reset_process_state()
    end)

    reset_process_state()
    :ok
  end

  test "validation boundary rejects malformed workflow input" do
    assert {:error, {:validation_failed, %{surface: :workflow_input, issues: issues}}} =
             Synaptic.start(ValidationWorkflow, %{email: "not-an-email"})

    assert Enum.any?(issues, &(&1.message =~ "required format"))
  end

  test "prompt security detects adversarial prompt-injection attempts" do
    assert {:error, {:prompt_security_failed, detections}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: AdversarialFixtures.prompt_injection()}],
               adapter: CaptureAdapter,
               prompt_security: [enabled: true, response: [on_detection: :error]]
             )

    assert Enum.any?(detections, &(&1.category in [:instruction_override, :data_exfiltration]))

    assert_receive {:telemetry_event, [:synaptic, :prompt_security, :detection], _measurements,
                    metadata},
                   1_000

    assert :instruction_override in metadata.detection_types
  end

  test "security policy blocks restricted PII from disallowed models and emits telemetry" do
    assert {:error, {:security_policy_failed, trace}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: AdversarialFixtures.restricted_pii()}],
               adapter: CaptureAdapter,
               model: "gpt-external",
               privacy: [enabled: true],
               security_policy: [
                 enabled: true,
                 pii: [
                   model_export: [
                     enabled: true,
                     sensitivity_at_or_above: :restricted_pii,
                     allow_models: ["gpt-safe"]
                   ]
                 ]
               ]
             )

    assert trace.decision == :deny

    assert_receive {:telemetry_event, [:synaptic, :security_policy, :decision], _measurements,
                    metadata},
                   1_000

    assert metadata.decision == :deny
    assert metadata.sensitivity == :restricted_pii
  end

  test "factuality emits violation telemetry for unsupported answers" do
    Process.put({CaptureAdapter, :result}, {:ok, "Paris is the capital of France."})

    assert {:ok, _message} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "What is the capital of France?"}],
               adapter: CaptureAdapter,
               factuality: [
                 enabled: true,
                 checks: [require_citations: true]
               ]
             )

    assert_receive {:telemetry_event, [:synaptic, :factuality, :check], _measurements, metadata},
                   1_000

    assert metadata.status == :violation
    assert :missing_citations in metadata.issue_codes
  end

  test "action controls emit telemetry for blocked external actions" do
    tool =
      %Synaptic.Tools.Tool{
        name: "send_email",
        description: "sends email",
        schema: %{
          type: "object",
          properties: %{email: %{type: "string"}},
          required: ["email"]
        },
        handler: fn _args -> %{status: "sent"} end
      }

    Process.delete({ToolLoopAdapter, :stage})

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Please send an email"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 rate_limits: [[tool: "send_email", max_calls: 1, window_ms: 60_000]]
               ]
             )

    Process.delete({ToolLoopAdapter, :stage})

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Please send an email"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 rate_limits: [[tool: "send_email", max_calls: 1, window_ms: 60_000]]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)
    assert payload["code"] == "rate_limit_exceeded"

    assert_receive {:telemetry_event, [:synaptic, :action_controls, :dispatch], _measurements,
                    metadata},
                   1_000

    assert metadata.status == :allow

    assert_receive {:telemetry_event, [:synaptic, :action_controls, :dispatch], _measurements,
                    metadata},
                   1_000

    assert metadata.status == :deny
    assert metadata.result_code == "rate_limit_exceeded"
  end

  defp attach(id, event) do
    :telemetry.attach(
      id,
      event,
      fn event_name, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry_event, event_name, measurements, metadata})
      end,
      self()
    )
  end

  defp reset_process_state do
    keys = [
      {CaptureAdapter, :last_messages},
      {CaptureAdapter, :result},
      {ToolLoopAdapter, :stage},
      :last_tool_message
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
