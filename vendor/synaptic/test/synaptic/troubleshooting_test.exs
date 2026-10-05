defmodule Synaptic.TroubleshootingTest do
  use ExUnit.Case, async: true

  test "explains egress failures with actionable suggestions" do
    explanation =
      Synaptic.explain_error(
        {:egress_blocked,
         %{
           code: :host_not_allowlisted,
           message: "blocked",
           details: %{host: "localhost"},
           suggestions: ["allowlist it"]
         }}
      )

    assert explanation.category == :egress
    assert explanation.code == :host_not_allowlisted
    assert "allowlist it" in explanation.suggestions
  end

  test "explains validation failures" do
    explanation =
      Synaptic.explain_error(
        {:validation_failed,
         %{
           surface: :workflow_input,
           step: :start,
           issues: [%{path: "#/email", code: :type_mismatch}]
         }}
      )

    assert explanation.category == :validation
    assert explanation.code == :validation_failed
    assert explanation.details.surface == :workflow_input
  end
end
