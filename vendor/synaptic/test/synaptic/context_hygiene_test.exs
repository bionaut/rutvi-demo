defmodule Synaptic.ContextHygieneTest do
  use ExUnit.Case

  defmodule CaptureAdapter do
    def chat(messages, _opts) do
      if test_pid = Process.get(:test_pid) do
        send(test_pid, {:captured_messages, messages})
      end

      {:ok, "ok"}
    end
  end

  defmodule LargeToolLoopAdapter do
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
                   "name" => "large_tool",
                   "arguments" => ~s({"query":"security"})
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

  defmodule MultiToolLoopAdapter do
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
                   "name" => "first_tool",
                   "arguments" => ~s({"query":"a"})
                 }
               }
             ]
           }}

        :second ->
          Process.put({__MODULE__, :stage}, :third)

          {:ok,
           %{
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => "call_2",
                 "function" => %{
                   "name" => "second_tool",
                   "arguments" => ~s({"query":"b"})
                 }
               }
             ]
           }}

        :third ->
          if test_pid = Process.get(:test_pid) do
            send(test_pid, {:third_round_messages, messages})
          end

          {:ok, "final"}
      end
    end
  end

  setup do
    reset_process_state()

    on_exit(fn ->
      reset_process_state()
    end)

    :ok
  end

  test "context hygiene is off by default" do
    tool = large_tool()

    assert {:ok, "final"} =
             Synaptic.Tools.chat([%{role: "user", content: "run the tool"}],
               adapter: LargeToolLoopAdapter,
               tools: [tool]
             )

    assert Process.get(:last_tool_message).content == String.duplicate("A", 3_000)
  end

  test "prompt metadata can expose static and dynamic section counts" do
    Process.put(:test_pid, self())

    assert {:ok, "ok", %{context_hygiene: %{prompt_context: prompt_context}}} =
             Synaptic.Tools.chat(
               [
                 %{role: "system", content: "You are precise."},
                 %{role: "user", content: "Hello"}
               ],
               adapter: CaptureAdapter,
               context_hygiene: [enabled: true, return_metadata: true]
             )

    assert prompt_context.static_count == 1
    assert prompt_context.dynamic_count == 1
    assert prompt_context.compacted_tool_messages == 0
  end

  test "oversized tool results are spilled to a handle and replaced with a preview" do
    tool = large_tool()

    assert {:ok, "final", %{context_hygiene: %{spilled_tool_results: [spill]}}} =
             Synaptic.Tools.chat([%{role: "user", content: "run the tool"}],
               adapter: LargeToolLoopAdapter,
               tools: [tool],
               context_hygiene: [
                 enabled: true,
                 return_metadata: true,
                 tool_results: [max_inline_chars: 200, preview_chars: 48]
               ]
             )

    preview = Jason.decode!(Process.get(:last_tool_message).content)

    assert preview["kind"] == "synaptic_tool_result_preview"
    assert preview["handle"] == spill.handle
    assert preview["reason"] == "oversized"
    refute preview["preview"] == String.duplicate("A", 3_000)

    assert {:ok, fetched} = Synaptic.fetch_spilled_tool_result(spill.handle)
    assert fetched.result == String.duplicate("A", 3_000)
    assert fetched.metadata.tool == "large_tool"
  end

  test "older tool results are compacted while recent ones stay inline" do
    Process.put(:test_pid, self())

    first_tool = named_large_tool("first_tool", String.duplicate("B", 600))
    second_tool = named_large_tool("second_tool", String.duplicate("C", 600))

    assert {:ok, "final", %{context_hygiene: %{spilled_tool_results: spills}}} =
             Synaptic.Tools.chat([%{role: "user", content: "run the tools"}],
               adapter: MultiToolLoopAdapter,
               tools: [first_tool, second_tool],
               context_hygiene: [
                 enabled: true,
                 return_metadata: true,
                 tool_results: [
                   spill_oversized: false,
                   compact_older: true,
                   keep_recent: 1,
                   max_inline_chars: 5_000,
                   preview_chars: 80
                 ]
               ]
             )

    assert_receive {:third_round_messages, messages}, 1_000

    tool_messages = Enum.filter(messages, fn message -> message.role == "tool" end)
    [first_message, second_message] = tool_messages

    first_preview = Jason.decode!(first_message.content)

    assert first_preview["kind"] == "synaptic_tool_result_preview"
    assert first_preview["tool"] == "first_tool"
    assert first_preview["reason"] == "history_compaction"
    assert second_message.content == String.duplicate("C", 600)
    assert Enum.any?(spills, &(&1.tool == "first_tool" and &1.reason == "history_compaction"))
  end

  test "sensitive previews are summarized instead of carrying raw identifiers" do
    tool =
      named_large_tool(
        "large_tool",
        String.duplicate("contact jane@example.com immediately ", 40)
      )

    assert {:ok, "final", %{context_hygiene: %{spilled_tool_results: [spill]}}} =
             Synaptic.Tools.chat([%{role: "user", content: "run the tool"}],
               adapter: LargeToolLoopAdapter,
               tools: [tool],
               context_hygiene: [
                 enabled: true,
                 return_metadata: true,
                 tool_results: [
                   max_inline_chars: 200,
                   preview_chars: 80,
                   summarize_sensitive_previews: true
                 ]
               ]
             )

    preview = Jason.decode!(Process.get(:last_tool_message).content)

    assert preview["kind"] == "synaptic_tool_result_preview"
    assert preview["handle"] == spill.handle
    assert preview["sensitive_types"] == ["email"]
    assert preview["preview"] =~ "sensitive content redacted"
    refute preview["preview"] =~ "jane@example.com"
  end

  test "spilled tool results can be tenant-scoped" do
    tool = large_tool()

    assert {:ok, "final", %{context_hygiene: %{spilled_tool_results: [spill]}}} =
             Synaptic.Tools.chat([%{role: "user", content: "run the tool"}],
               adapter: LargeToolLoopAdapter,
               tools: [tool],
               tenant: "tenant-a",
               context_hygiene: [
                 enabled: true,
                 return_metadata: true,
                 tool_results: [max_inline_chars: 200, preview_chars: 48]
               ]
             )

    assert {:error, :forbidden} = Synaptic.fetch_spilled_tool_result(spill.handle)
    assert {:ok, _entry} = Synaptic.fetch_spilled_tool_result(spill.handle, tenant: "tenant-a")
  end

  defp large_tool do
    named_large_tool("large_tool", String.duplicate("A", 3_000))
  end

  defp named_large_tool(name, result) do
    %Synaptic.Tools.Tool{
      name: name,
      description: "returns a large payload",
      schema: %{
        type: "object",
        properties: %{query: %{type: "string"}},
        required: ["query"]
      },
      handler: fn _args -> result end
    }
  end

  defp reset_process_state do
    keys = [
      :test_pid,
      :last_tool_message,
      {LargeToolLoopAdapter, :stage},
      {MultiToolLoopAdapter, :stage}
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
