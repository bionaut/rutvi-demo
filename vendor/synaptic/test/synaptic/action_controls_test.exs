defmodule Synaptic.ActionControlsTest do
  use ExUnit.Case

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
                   "name" => Process.get(:next_tool_name),
                   "arguments" => Process.get(:next_tool_args_json, "{}")
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
    original = Application.get_env(:synaptic, Synaptic.ActionControls)
    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.ActionControls, original)
      reset_process_state()
      Synaptic.ActionControls.prune_expired()
    end)

    :ok
  end

  test "action controls are off by default" do
    tool = counter_tool("default_off_tool")

    Process.put(:next_tool_name, "default_off_tool")
    Process.put(:next_tool_args_json, ~s({"idempotency_key":"abc"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it"}],
               adapter: ToolLoopAdapter,
               tools: [tool]
             )

    assert Process.get(:counter_calls) == 1
  end

  test "idempotency can be required for destructive tools" do
    tool = counter_tool("destructive_tool", destructive: true)

    Process.put(:next_tool_name, "destructive_tool")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 idempotency: [enabled: true, require_for: [destructive: true]]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "action_blocked"
    assert payload["reason"] == "idempotency_key_required"
    assert Process.get(:counter_calls, 0) == 0
  end

  test "duplicate idempotency keys can return the cached result instead of re-running the tool" do
    tool = counter_tool("cached_tool", destructive: true)
    run_id = "action-controls-idempotency"

    Process.put(:next_tool_name, "cached_tool")
    Process.put(:next_tool_args_json, ~s({"idempotency_key":"abc"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it"}],
               run_id: run_id,
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 idempotency: [
                   enabled: true,
                   require_for: [destructive: true],
                   duplicate_behavior: :return_cached
                 ]
               ]
             )

    Process.delete({ToolLoopAdapter, :stage})
    Process.put(:next_tool_name, "cached_tool")
    Process.put(:next_tool_args_json, ~s({"idempotency_key":"abc"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it again"}],
               run_id: run_id,
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 idempotency: [
                   enabled: true,
                   require_for: [destructive: true],
                   duplicate_behavior: :return_cached
                 ]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["status"] == "count-1"
    assert Process.get(:counter_calls) == 1
  end

  test "concurrent duplicate idempotency keys execute a destructive action once" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    run_id = "concurrent-idempotency-#{System.unique_integer([:positive])}"

    opts = [
      run_id: run_id,
      action_controls: [
        enabled: true,
        idempotency: [
          enabled: true,
          require_for: [destructive: true],
          duplicate_behavior: :return_cached
        ]
      ]
    ]

    entry = %{
      llm_name: "destructive_tool",
      source: %{type: :local, server: nil, remote_name: "destructive_tool"},
      metadata: %{destructive: true, risk: :high}
    }

    state = Synaptic.ActionControls.new(opts)

    invoke = fn ->
      Synaptic.ActionControls.dispatch(
        entry,
        %{"idempotency_key" => "same-key"},
        opts,
        state,
        fn ->
          Agent.get_and_update(counter, fn count ->
            Process.sleep(25)
            {{:ok, "result-#{count + 1}"}, count + 1}
          end)
        end
      )
    end

    results = [Task.async(invoke), Task.async(invoke)] |> Task.await_many()

    assert Agent.get(counter, & &1) == 1
    assert Enum.all?(results, fn {result, _state} -> result == {:ok, "result-1"} end)
  end

  test "rate limits can block a second invocation" do
    tool = counter_tool("rate_limited_tool")

    Process.put(:next_tool_name, "rate_limited_tool")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 rate_limits: [[tool: "rate_limited_tool", max_calls: 1, window_ms: 60_000]]
               ]
             )

    Process.delete({ToolLoopAdapter, :stage})
    Process.put(:next_tool_name, "rate_limited_tool")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it again"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 rate_limits: [[tool: "rate_limited_tool", max_calls: 1, window_ms: 60_000]]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "rate_limit_exceeded"
    assert payload["reason"] =~ "rate_limit_exceeded"
    assert Process.get(:counter_calls) == 1
  end

  test "blast radius caps actions within the same run" do
    tool = counter_tool("blast_radius_tool")
    run_id = "action-controls-blast-radius"

    Process.put(:next_tool_name, "blast_radius_tool")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it"}],
               run_id: run_id,
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 blast_radius: [[tool: "blast_radius_tool", max_calls: 1]]
               ]
             )

    Process.delete({ToolLoopAdapter, :stage})
    Process.put(:next_tool_name, "blast_radius_tool")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it again"}],
               run_id: run_id,
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 blast_radius: [[tool: "blast_radius_tool", max_calls: 1]]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "blast_radius_exceeded"
    assert payload["reason"] =~ "blast_radius_exceeded"
    assert Process.get(:counter_calls) == 1
  end

  test "retry policy can rerun transient tool failures" do
    tool = retry_tool("retry_tool")

    Process.put(:next_tool_name, "retry_tool")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final", %{action_controls: %{events: [event]}}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               action_controls: [
                 enabled: true,
                 return_metadata: true,
                 retries: [
                   enabled: true,
                   max_attempts: 2,
                   retry_codes: ["tool_call_failed"],
                   sources: [:local]
                 ]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["status"] == "ok"
    assert Process.get(:retry_tool_calls) == 2
    assert event.attempts == 2
    assert event.status == :allow
  end

  defp counter_tool(name, opts \\ []) do
    %Synaptic.Tools.Tool{
      name: name,
      description: "counts invocations",
      schema: %{type: "object", properties: %{}, required: []},
      destructive: Keyword.get(opts, :destructive, false),
      handler: fn _args ->
        count = Process.get(:counter_calls, 0) + 1
        Process.put(:counter_calls, count)
        %{status: "count-#{count}"}
      end
    }
  end

  defp retry_tool(name) do
    %Synaptic.Tools.Tool{
      name: name,
      description: "fails once, then succeeds",
      schema: %{type: "object", properties: %{}, required: []},
      handler: fn _args ->
        count = Process.get(:retry_tool_calls, 0) + 1
        Process.put(:retry_tool_calls, count)

        if count == 1 do
          %{error: true, code: "tool_call_failed", message: "temporary"}
        else
          %{status: "ok"}
        end
      end
    }
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      {ToolLoopAdapter, :stage},
      :next_tool_name,
      :next_tool_args_json,
      :last_tool_message,
      :counter_calls,
      :retry_tool_calls
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
