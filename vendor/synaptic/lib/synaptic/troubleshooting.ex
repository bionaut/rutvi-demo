defmodule Synaptic.Troubleshooting do
  @moduledoc false

  def explain({:validation_failed, %{surface: surface, step: step, issues: issues}}) do
    %{
      category: :validation,
      code: :validation_failed,
      summary: "Input validation failed on #{inspect(surface)}.",
      details: %{surface: surface, step: step, issues: issues},
      suggestions: [
        "Check the reported field paths and types in the `issues` list.",
        "Use `Synaptic.explain_security/2` to confirm whether validation defaults are active for this posture."
      ]
    }
  end

  def explain({:security_configuration_failed, report}) when is_map(report) do
    %{
      category: :security_configuration,
      code: :security_configuration_failed,
      summary: "Security posture diagnostics blocked execution before the runtime started.",
      details: %{diagnostics: Map.get(report, :diagnostics), profile: Map.get(report, :profile)},
      suggestions: [
        "Inspect `diagnostics.errors` for the missing or contradictory controls.",
        "Call `Synaptic.explain_security/2` with the same options to see the effective composed posture."
      ]
    }
  end

  def explain({:egress_blocked, %{code: code} = detail}) do
    %{
      category: :egress,
      code: code,
      summary: detail.message,
      details: Map.drop(detail, [:message, :suggestions]),
      suggestions:
        detail.suggestions ++
          [
            "Review the effective egress posture with `Synaptic.explain_security(:chat, ...)` or `Synaptic.explain_security(:workflow, ...)`."
          ]
    }
  end

  def explain({:connector_gateway_blocked, %{code: code} = detail}) do
    %{
      category: :connector_gateway,
      code: code,
      summary: detail.message,
      details: Map.drop(detail, [:message, :suggestions]),
      suggestions:
        detail.suggestions ++
          [
            "Check connector gateway settings for managed-only mode, TLS requirements, and passthrough header rules."
          ]
    }
  end

  def explain(%{error: true, code: "policy_denied"} = payload) do
    %{
      category: :policy,
      code: :policy_denied,
      summary: Map.get(payload, :message) || "Tool execution was denied by policy.",
      details: payload,
      suggestions: [
        "Inspect the attached decision trace or enable `policy: [return_decisions: true]` for more detail.",
        "Use `Synaptic.explain_security/2` to confirm the active tool policy and approval posture."
      ]
    }
  end

  def explain(%{error: true, code: "approval_required"} = payload) do
    %{
      category: :approval,
      code: :approval_required,
      summary: Map.get(payload, :message) || "Tool execution requires approval.",
      details: payload,
      suggestions: [
        "Inspect the returned approval payload to see which rule requested approval.",
        "Tighten or relax approval thresholds only after reviewing tool metadata and risk tier."
      ]
    }
  end

  def explain(%{error: true, code: "invalid_arguments"} = payload) do
    %{
      category: :tool_arguments,
      code: :invalid_arguments,
      summary: Map.get(payload, :message) || "Tool arguments failed schema validation.",
      details: payload,
      suggestions: [
        "Inspect the returned `details` list for the exact field mismatch.",
        "Confirm the tool schema and argument serialization are aligned."
      ]
    }
  end

  def explain(other) do
    %{
      category: :unknown,
      code: :unknown,
      summary: "No built-in troubleshooting guide matched this error.",
      details: %{value: other},
      suggestions: [
        "Inspect the raw error value.",
        "If the error came from a security boundary, `Synaptic.explain_security/2` may still help narrow the active controls."
      ]
    }
  end
end
