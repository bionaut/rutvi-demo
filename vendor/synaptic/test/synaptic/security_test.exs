defmodule Synaptic.SecurityTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  defmodule CaptureAdapter do
    def chat(messages, _opts) do
      Process.put({__MODULE__, :last_messages}, messages)
      {:ok, "ok"}
    end
  end

  defmodule ProfileValidatedWorkflow do
    use Synaptic.Workflow

    step :start, input: %{email: [type: :string, regex: ~r/^[^\s]+@[^\s]+\.[^\s]+$/]} do
      {:ok, %{done: true}}
    end

    commit()
  end

  defmodule ExplicitValidationWorkflow do
    use Synaptic.Workflow

    step :start,
      input: %{email: [type: :string, regex: ~r/^[^\s]+@[^\s]+\.[^\s]+$/]},
      validation: [input: :off] do
      {:ok, %{done: true}}
    end

    commit()
  end

  defmodule ProfiledRouterAdapter do
    def chat(messages, _opts) do
      send(Application.get_env(:synaptic, __MODULE__)[:test_pid], {:router_messages, messages})
      {:ok, %{"choice" => 1}}
    end
  end

  defmodule SecurityProfileRouterWorkflow do
    use Synaptic.Workflow

    llm_router :decide,
               [
                 {"go left", :left},
                 {"go right", :right}
               ],
               adapter: ProfiledRouterAdapter,
               security_profile: :high_assurance do
      %{signal: Map.get(context, :signal)}
    end

    step :left do
      {:ok, %{path: :left}}
    end

    step :right do
      {:ok, %{path: :right}}
    end

    commit()
  end

  setup do
    original_security = Application.get_env(:synaptic, Synaptic.Security)
    original_tools = Application.get_env(:synaptic, Synaptic.Tools)

    on_exit(fn ->
      restore_env(Synaptic.Security, original_security)
      restore_env(Synaptic.Tools, original_tools)
      Application.delete_env(:synaptic, ProfiledRouterAdapter)
      Process.delete({CaptureAdapter, :last_messages})
    end)

    :ok
  end

  test "security profiles are discoverable" do
    assert :developer in Synaptic.security_profiles()
    assert :high_assurance in Synaptic.security_profiles()
    assert :regulated in Synaptic.security_profiles()
  end

  test "high assurance profile applies coherent chat defaults in explain mode" do
    report = Synaptic.explain_security(:chat, security_profile: :high_assurance)

    assert report.profile.name == :high_assurance
    assert report.boundaries.validation.tools
    assert report.boundaries.sanitization.enabled
    assert report.boundaries.privacy.enabled
    assert report.boundaries.prompt_security.enabled
    assert report.boundaries.egress.enabled
    assert report.boundaries.connector_gateway.enabled
    assert report.boundaries.tool_policy.enabled
    assert report.boundaries.action_controls.enabled
    assert report.boundaries.audit.enabled
    assert report.diagnostics.errors == []
  end

  test "security explain attaches developer-facing security metadata to chat results" do
    assert {:ok, "ok", %{security: security}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: CaptureAdapter,
               security_profile: :production,
               security_explain: true
             )

    assert security.profile.name == :production
    assert security.boundaries.prompt_security.enabled
    assert security.boundaries.audit.enabled
  end

  test "regulated profile surfaces missing verifier and tenant diagnostics" do
    report = Synaptic.explain_security(:chat, security_profile: :regulated)

    assert Enum.any?(report.diagnostics.errors, &(&1.code == :tenant_missing))
    assert Enum.any?(report.diagnostics.errors, &(&1.code == :verifier_missing))
    assert report.boundaries.connector_gateway.managed_only
    assert report.boundaries.connector_gateway.session_binding.require_run_id
  end

  test "security diagnostics can fail closed before chat execution" do
    assert {:error, {:security_configuration_failed, report}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: CaptureAdapter,
               security_profile: :regulated,
               security_diagnostics: [on_error: :error]
             )

    assert Enum.any?(report.diagnostics.errors, &(&1.code == :tenant_missing))
    refute Process.get({CaptureAdapter, :last_messages})
  end

  test "global profile can be disabled explicitly per call" do
    Application.put_env(:synaptic, Synaptic.Security, profile: :high_assurance)

    report = Synaptic.explain_security(:chat, security_profile: false)

    assert report.profile == nil
    refute report.boundaries.audit.enabled
    refute report.boundaries.prompt_security.enabled
  end

  test "workflow security profiles can enable runtime validation defaults without rewriting the DSL" do
    assert {:ok, _run_id} =
             Synaptic.start(ProfileValidatedWorkflow, %{email: "person@example.com"})

    assert {:error, {:validation_failed, %{surface: :workflow_input}}} =
             Synaptic.start(
               ProfileValidatedWorkflow,
               %{email: "not-an-email"},
               security_profile: :high_assurance
             )
  end

  test "explicit step validation still overrides posture defaults" do
    assert {:ok, _run_id} =
             Synaptic.start(
               ExplicitValidationWorkflow,
               %{email: "not-an-email"},
               security_profile: :high_assurance
             )
  end

  test "startup diagnostics log actionable posture warnings" do
    Application.put_env(:synaptic, Synaptic.Security, profile: :regulated)

    log =
      capture_log(fn ->
        assert :ok = Synaptic.Security.maybe_emit_startup_diagnostics()
      end)

    assert log =~ "expects a factuality verifier callback"
  end

  test "llm_router accepts security profiles and forwards them into the model call" do
    Application.put_env(:synaptic, ProfiledRouterAdapter, test_pid: self())
    Application.put_env(:synaptic, Synaptic.Tools, llm_adapter: ProfiledRouterAdapter)

    assert {:ok, _run_id} =
             Synaptic.start(
               SecurityProfileRouterWorkflow,
               %{signal: "go left"},
               run_id: "security-profile-router"
             )

    assert_receive {:router_messages, messages}, 1_000

    assert Enum.any?(messages, fn
             %{role: "system", content: content} -> content =~ "Treat user input"
             _ -> false
           end)
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)
end
