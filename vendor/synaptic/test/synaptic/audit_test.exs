defmodule Synaptic.AuditTest do
  use ExUnit.Case

  defmodule CaptureAdapter do
    def chat(messages, _opts) do
      Process.put({__MODULE__, :last_messages}, messages)
      Process.get({__MODULE__, :result}, {:ok, "ok"})
    end
  end

  defmodule ToolLoopAdapter do
    def chat(_messages, _opts) do
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
                   "name" => Process.get(:next_tool_name, "send_email"),
                   "arguments" =>
                     Process.get(:next_tool_args_json, ~s({"email":"jane@example.com"}))
                 }
               }
             ]
           }}

        :second ->
          Process.put(:last_tool_message, Process.get(:last_tool_message))
          Process.get({__MODULE__, :result}, {:ok, "final"})
      end
    end
  end

  defmodule AuditValidationWorkflow do
    use Synaptic.Workflow

    step :start, output: %{required_field: :string}, validation: [output: :strict] do
      {:ok, %{}}
    end

    commit()
  end

  setup do
    original_audit = Application.get_env(:synaptic, Synaptic.Audit)
    handler_id = "audit-test-#{System.unique_integer([:positive])}"
    reset_process_state()

    :telemetry.attach(
      handler_id,
      [:synaptic, :audit, :record],
      fn _event, _measurements, metadata, test_pid ->
        send(test_pid, {:audit_telemetry, metadata})
      end,
      self()
    )

    on_exit(fn ->
      restore_env(Synaptic.Audit, original_audit)
      :telemetry.detach(handler_id)
      reset_process_state()
    end)

    :ok
  end

  test "audit is off by default" do
    assert {:ok, "ok"} =
             Synaptic.Tools.chat([%{role: "user", content: "hello"}], adapter: CaptureAdapter)

    refute_receive {:audit_telemetry, _metadata}, 100
  end

  test "audit records sanitized tool and guardrail events without leaking raw prompt values" do
    tool =
      %Synaptic.Tools.Tool{
        name: "send_email",
        description: "Sends email",
        schema: %{
          type: "object",
          properties: %{email: %{type: "string"}},
          required: ["email"]
        },
        handler: fn _args ->
          flunk("tool should not execute when blocked by policy")
        end
      }

    Process.put(:next_tool_name, "send_email")
    Process.put(:next_tool_args_json, ~s({"email":"jane@example.com"}))
    Process.delete({ToolLoopAdapter, :stage})

    assert {:ok, "final", %{audit: %{audit_id: audit_id, record_count: record_count}}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Please email jane@example.com"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               privacy: [enabled: true],
               policy: [
                 enabled: true,
                 rules: [[decision: :deny, tools: ["send_email"], reason: "email_disabled"]]
               ],
               audit: [enabled: true, return_metadata: true]
             )

    assert record_count >= 4

    records = Synaptic.audit_records(audit_id)

    assert Enum.any?(records, &(&1.event == :request_prepared))
    assert Enum.any?(records, &(&1.event == :prompt_prepared))
    assert Enum.any?(records, &(&1.event == :tool_call_requested))
    assert Enum.any?(records, &(&1.event == :pii_detected))
    assert Enum.any?(records, &(&1.event == :pii_transformed))
    assert Enum.any?(records, &(&1.event == :pii_transmitted))

    blocked_record =
      Enum.find(records, fn record ->
        record.event == :tool_call_blocked and record.metadata.tool == "send_email"
      end)

    assert blocked_record
    assert blocked_record.metadata.status == "blocked"
    assert blocked_record.metadata.decision == "deny"
    assert :ok = Synaptic.verify_audit_records(audit_id)
    refute inspect(records) =~ "jane@example.com"

    assert_receive {:audit_telemetry, metadata}, 1_000
    refute Map.has_key?(metadata, :messages)
    refute Map.has_key?(metadata, :args)
    refute inspect(metadata) =~ "jane@example.com"
  end

  test "privacy audit reasons distinguish ordinary and streamed prompt preparation" do
    common_opts = [
      adapter: CaptureAdapter,
      privacy: [enabled: true],
      audit: [enabled: true, return_metadata: true]
    ]

    assert {:ok, "ok", %{audit: %{audit_id: ordinary_id}}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Contact jane@example.com"}],
               common_opts
             )

    ordinary_reasons =
      ordinary_id
      |> Synaptic.audit_records()
      |> Enum.filter(&(&1.event in [:pii_detected, :pii_transformed]))
      |> Enum.map(& &1.metadata.reason)

    assert ordinary_reasons != []
    assert Enum.uniq(ordinary_reasons) == ["prompt_preparation"]

    assert {:ok, "ok", %{audit: %{audit_id: stream_id}}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Contact jane@example.com"}],
               Keyword.put(common_opts, :stream, true)
             )

    stream_reasons =
      stream_id
      |> Synaptic.audit_records()
      |> Enum.filter(&(&1.event in [:pii_detected, :pii_transformed]))
      |> Enum.map(& &1.metadata.reason)

    assert stream_reasons != []
    assert Enum.uniq(stream_reasons) == ["stream_prompt_preparation"]
  end

  test "delete_run_artifacts removes audit records and spilled tool results" do
    run_id = "audit-delete-run"

    tool =
      %Synaptic.Tools.Tool{
        name: "bulk_lookup",
        description: "Returns a large result",
        schema: %{
          type: "object",
          properties: %{query: %{type: "string"}},
          required: ["query"]
        },
        handler: fn _args ->
          String.duplicate("A", 400)
        end
      }

    Process.put(:next_tool_name, "bulk_lookup")
    Process.put(:next_tool_args_json, ~s({"query":"paris"}))
    Process.delete({ToolLoopAdapter, :stage})

    assert {:ok, "final",
            %{
              audit: %{audit_id: ^run_id},
              context_hygiene: %{spilled_tool_results: [spill | _]}
            }} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run the tool"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               run_id: run_id,
               context_hygiene: [
                 enabled: true,
                 return_metadata: true,
                 tool_results: [max_inline_chars: 20, preview_chars: 8]
               ],
               audit: [enabled: true, return_metadata: true]
             )

    assert {:ok, _spill_entry} = Synaptic.fetch_spilled_tool_result(spill.handle)
    assert Synaptic.audit_records(run_id) != []

    summary = Synaptic.delete_run_artifacts(run_id)

    assert summary.run_id == run_id
    assert summary.audit_records_deleted > 0
    assert summary.spilled_tool_results_deleted > 0
    assert Synaptic.audit_records(run_id) == []
    assert {:error, :not_found} = Synaptic.fetch_spilled_tool_result(spill.handle)

    deletion_record =
      Synaptic.audit_records("synaptic_deletions")
      |> Enum.find(fn record ->
        record.event == :artifacts_deleted and record.metadata.run_id == run_id
      end)

    assert deletion_record
    assert deletion_record.metadata.status == "deleted"
  end

  test "workflow validation failures are captured in audit records" do
    assert {:ok, run_id} =
             Synaptic.start(AuditValidationWorkflow, %{}, audit: [enabled: true])

    snapshot = wait_for(run_id, :failed)
    assert match?({:validation_failed, _}, snapshot.last_error)

    records = Synaptic.audit_records(run_id)

    validation_record =
      Enum.find(records, fn record ->
        record.event == :step_error and record.metadata.reason == "validation_failed"
      end)

    assert validation_record
    assert validation_record.metadata.validation_surface == "step_output"
    assert validation_record.metadata.issue_codes == ["missing_required"]
  end

  test "concurrent audit appends retain a single verifiable chain" do
    audit_id = "concurrent-audit-#{System.unique_integer([:positive])}"

    1..50
    |> Task.async_stream(
      fn index ->
        Synaptic.AuditStore.put(audit_id, audit_id, :test, :concurrent, %{index: index})
      end,
      max_concurrency: 20,
      ordered: false
    )
    |> Stream.run()

    assert length(Synaptic.audit_records(audit_id)) == 50
    assert :ok = Synaptic.verify_audit_records(audit_id)
  end

  test "verification accepts a retained chain suffix after its expired prefix is pruned" do
    audit_id = "retained-audit-#{System.unique_integer([:positive])}"
    Synaptic.AuditStore.put(audit_id, audit_id, :test, :short_lived, %{}, 1)
    Synaptic.AuditStore.put(audit_id, audit_id, :test, :retained, %{}, 10_000)
    Process.sleep(5)

    assert [%{event: :retained}] = Synaptic.audit_records(audit_id)
    assert :ok = Synaptic.verify_audit_records(audit_id)
  end

  test "security tables are owned by the supervised store process" do
    owner = Process.whereis(Synaptic.SecurityStoreOwner)
    assert is_pid(owner)
    assert :ets.info(:synaptic_audit_store, :owner) == owner
    assert :ets.info(:synaptic_tool_result_store, :owner) == owner
    assert :ets.info(:synaptic_action_controls, :owner) == owner
    assert :ets.info(:synaptic_connector_gateway, :owner) == owner
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

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      {CaptureAdapter, :last_messages},
      {CaptureAdapter, :result},
      {ToolLoopAdapter, :stage},
      {ToolLoopAdapter, :result},
      :next_tool_name,
      :next_tool_args_json,
      :last_tool_message
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
