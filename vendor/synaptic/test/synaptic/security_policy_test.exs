defmodule Synaptic.SecurityPolicyTest do
  use ExUnit.Case

  defmodule CaptureAdapter do
    def chat(messages, _opts) do
      Process.put({__MODULE__, :last_messages}, messages)
      {:ok, "ok"}
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
                   "arguments" => ~s({"email":"[PII_EMAIL_1]"})
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

  setup do
    original = Application.get_env(:synaptic, Synaptic.SecurityPolicy)
    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.SecurityPolicy, original)
      reset_process_state()
    end)

    :ok
  end

  test "security policy is off by default" do
    assert {:ok, "ok"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Email jane@example.com"}],
               adapter: CaptureAdapter,
               privacy: [enabled: true]
             )

    assert Process.get({CaptureAdapter, :last_messages})
  end

  test "security policy can block restricted PII from leaving through disallowed models" do
    assert {:error, {:security_policy_failed, trace}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "SSN 123-45-6789"}],
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

    assert trace.reason == "restricted_pii_model_export_blocked"
    refute Process.get({CaptureAdapter, :last_messages})
  end

  test "security policy can allow an explicitly approved model to receive restricted PII" do
    assert {:ok, "ok"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "SSN 123-45-6789"}],
               adapter: CaptureAdapter,
               model: "gpt-safe",
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

    assert Process.get({CaptureAdapter, :last_messages})
  end

  test "security policy can require a tenant boundary before prompt execution" do
    assert {:error, {:security_policy_failed, trace}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: CaptureAdapter,
               security_policy: [enabled: true, tenant: [required_surfaces: [:prompt]]]
             )

    assert trace.reason == "tenant_required"

    assert {:ok, "ok"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: CaptureAdapter,
               tenant: "tenant-a",
               security_policy: [enabled: true, tenant: [required_surfaces: [:prompt]]]
             )
  end

  test "security policy can block tool access when prompt context carries PII" do
    tool = email_tool()

    Process.delete({ToolLoopAdapter, :stage})

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Email jane@example.com"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               privacy: [enabled: true],
               security_policy: [
                 enabled: true,
                 pii: [
                   tool_access: [
                     enabled: true,
                     sensitivity_at_or_above: :pii,
                     allowed_tools: ["safe_lookup"]
                   ]
                 ]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "policy_denied"
    assert payload["reason"] == "pii_tool_access_blocked"
    refute Process.get(:tool_called)
  end

  test "security policy can allow explicitly approved PII tools" do
    tool = email_tool()

    Process.delete({ToolLoopAdapter, :stage})

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Email jane@example.com"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               privacy: [enabled: true],
               security_policy: [
                 enabled: true,
                 pii: [
                   tool_access: [
                     enabled: true,
                     sensitivity_at_or_above: :pii,
                     allowed_tools: ["send_email"]
                   ]
                 ]
               ]
             )

    assert Process.get(:tool_called) == %{"email" => "jane@example.com"}
  end

  defp email_tool do
    %Synaptic.Tools.Tool{
      name: "send_email",
      description: "sends an email",
      schema: %{
        type: "object",
        properties: %{email: %{type: "string"}},
        required: ["email"]
      },
      data_class: :pii,
      handler: fn args ->
        Process.put(:tool_called, args)
        %{status: "sent"}
      end
    }
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      {CaptureAdapter, :last_messages},
      {ToolLoopAdapter, :stage},
      :last_tool_message,
      :tool_called
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
