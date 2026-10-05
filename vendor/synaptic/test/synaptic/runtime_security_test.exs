defmodule Synaptic.RuntimeSecurityTest do
  use ExUnit.Case

  defmodule RuntimeSecurityWorkflow do
    use Synaptic.Workflow

    step :collect do
      suspend_for_human("Reply to jane@example.com", %{}, %{note: "contact jane@example.com"})
    end

    step :finish do
      {:ok, %{done: true, contact: context.human_input["email"] || context.human_input[:email]}}
    end

    commit()
  end

  defmodule HistoryLimitWorkflow do
    use Synaptic.Workflow

    step :one do
      {:ok, %{one: "jane@example.com"}}
    end

    step :two do
      {:ok, %{two: "123-45-6789"}}
    end

    step :three do
      {:ok, %{three: "done"}}
    end

    commit()
  end

  test "runtime security redacts history, events, and snapshots when enabled" do
    run_id = "runtime-security-redaction"
    :ok = Synaptic.subscribe(run_id)

    on_exit(fn ->
      Synaptic.unsubscribe(run_id)
    end)

    assert {:ok, ^run_id} =
             Synaptic.start(
               RuntimeSecurityWorkflow,
               %{contact: "jane@example.com"},
               run_id: run_id,
               runtime_security: [
                 enabled: true,
                 snapshot: [redact: true]
               ]
             )

    assert_receive {:synaptic_event,
                    %{event: :waiting_for_human, message: message, run_id: ^run_id}},
                   1_000

    refute message =~ "jane@example.com"
    assert message =~ "j***@example.com"

    snapshot = wait_for(run_id, :waiting_for_human)
    history = Synaptic.history(run_id)

    refute inspect(snapshot) =~ "jane@example.com"
    refute inspect(history) =~ "jane@example.com"
    assert inspect(snapshot) =~ "j***@example.com"
    assert inspect(history) =~ "j***@example.com"
  end

  test "runtime security can cap history and purge terminal context" do
    run_id = "runtime-security-retention"

    assert {:ok, ^run_id} =
             Synaptic.start(
               HistoryLimitWorkflow,
               %{},
               run_id: run_id,
               runtime_security: [
                 enabled: true,
                 history: [max_entries: 2],
                 retention: [purge_context_on_terminal: true]
               ]
             )

    snapshot = wait_for(run_id, :completed)
    history = Synaptic.history(run_id)

    assert length(history) <= 2
    assert snapshot.context == %{}
  end

  test "terminal cleanup preserves a redacted failure reason" do
    security =
      Synaptic.RuntimeSecurity.new(
        runtime_security: [
          enabled: true,
          retention: [purge_context_on_terminal: true]
        ]
      )

    cleaned =
      Synaptic.RuntimeSecurity.terminal_cleanup(
        %{
          context: %{email: "jane@example.com"},
          waiting: %{message: "jane@example.com"},
          last_error: {:failed_for, "jane@example.com"}
        },
        security
      )

    assert cleaned.context == %{}
    assert cleaned.waiting == nil
    assert cleaned.last_error == {:failed_for, "j***@example.com"}
  end

  defp wait_for(run_id, status, attempts \\ 20)
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
