defmodule Synaptic.PolicyHooksTest do
  use ExUnit.Case

  alias Synaptic.MCP.Discovery

  defmodule CaptureAdapter do
    def chat(messages, _opts) do
      if test_pid = Process.get(:test_pid) do
        send(test_pid, {:captured_messages, messages})
      end

      {:ok, "raw-output"}
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

  defmodule MCPAdapter do
    use Synaptic.MCP.Adapter

    @impl true
    def discover(_connection, _opts) do
      Process.put(
        {__MODULE__, :discover_calls},
        Process.get({__MODULE__, :discover_calls}, 0) + 1
      )

      {:ok,
       %Discovery{
         tools: [
           %{
             name: "search_issues",
             description: "Search issues",
             input_schema: %{
               type: "object",
               properties: %{query: %{type: "string"}},
               required: ["query"]
             }
           }
         ],
         resources_supported?: false,
         resources: nil,
         server_info: %{},
         warnings: []
       }}
    end

    @impl true
    def call_tool(connection, remote_name, args, _opts) do
      Process.put({__MODULE__, :last_call_tool}, {connection.name, remote_name, args})
      {:ok, %{remote: remote_name, args: args}}
    end

    @impl true
    def list_resources(_connection, _opts), do: {:ok, []}

    @impl true
    def read_resource(_connection, _uri, _opts), do: {:ok, %{"contents" => []}}
  end

  @messages [%{role: "user", content: "Email me at jane@example.com"}]

  setup do
    original_hooks = Application.get_env(:synaptic, Synaptic.PolicyHooks)

    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.PolicyHooks, original_hooks)
      reset_process_state()
    end)

    :ok
  end

  test "hooks are off by default even when hook definitions are passed" do
    Process.put(:test_pid, self())

    assert {:ok, "raw-output"} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               hooks: [
                 pre_prompt: [
                   fn payload ->
                     {:ok, %{payload | messages: [%{role: "user", content: "mutated"}]}}
                   end
                 ]
               ]
             )

    assert_receive {:captured_messages, [%{content: content}]}, 1_000
    assert content == "Email me at jane@example.com"
  end

  test "pre_prompt hooks can rewrite messages before the adapter sees them" do
    Process.put(:test_pid, self())

    assert {:ok, "raw-output"} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               hooks: [
                 enabled: true,
                 pre_prompt: [
                   fn payload ->
                     updated_messages =
                       Enum.map(payload.messages, fn
                         %{role: "user", content: content} = message ->
                           %{message | content: content <> "\n[hooked]"}

                         message ->
                           message
                       end)

                     {:ok, %{payload | messages: updated_messages}}
                   end
                 ]
               ]
             )

    assert_receive {:captured_messages, [%{content: content}]}, 1_000
    assert content =~ "[hooked]"
  end

  test "post_output hooks can rewrite model output" do
    assert {:ok, "rewritten-output"} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               hooks: [
                 enabled: true,
                 post_output: [
                   fn payload ->
                     {:ok, %{payload | result: {:ok, "rewritten-output"}}}
                   end
                 ]
               ]
             )
  end

  test "pre_prompt hook failures are fail-open by default" do
    Process.put(:test_pid, self())

    assert {:ok, "raw-output"} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               hooks: [
                 enabled: true,
                 pre_prompt: [fn _payload -> {:error, :hook_boom} end]
               ]
             )

    assert_receive {:captured_messages, [%{content: content}]}, 1_000
    assert content == "Email me at jane@example.com"
  end

  test "hook failure policy can fail closed on pre_prompt" do
    Process.put(:test_pid, self())

    assert {:error, {:hook_failure, :pre_prompt, "hook_boom"}} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               hooks: [
                 enabled: true,
                 failure_policy: [pre_prompt: :closed],
                 pre_prompt: [fn _payload -> {:error, :hook_boom} end]
               ]
             )

    refute_receive {:captured_messages, _messages}, 100
  end

  test "pre_tool hooks can deny local tools before handler execution" do
    tool = echo_tool()

    Process.put(:next_tool_name, "echo")
    Process.put(:next_tool_args_json, ~s({"text":"hello"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat([%{role: "user", content: "hi"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               hooks: [
                 enabled: true,
                 pre_tool: [fn _payload -> {:deny, "tool_blocked"} end]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "hook_denied"
    assert payload["surface"] == "pre_tool"
    assert payload["reason"] == "tool_blocked"
    refute Process.get(:tool_called_with)
  end

  test "pre_tool hook failures are fail-closed by default" do
    tool = echo_tool()

    Process.put(:next_tool_name, "echo")
    Process.put(:next_tool_args_json, ~s({"text":"hello"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat([%{role: "user", content: "hi"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               hooks: [
                 enabled: true,
                 pre_tool: [fn _payload -> {:error, :hook_boom} end]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "hook_failure"
    assert payload["surface"] == "pre_tool"
    assert payload["reason"] == "hook_boom"
    refute Process.get(:tool_called_with)
  end

  test "post_tool hooks can rewrite tool results before they re-enter the loop" do
    tool = echo_tool()

    Process.put(:next_tool_name, "echo")
    Process.put(:next_tool_args_json, ~s({"text":"hello"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat([%{role: "user", content: "hi"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               hooks: [
                 enabled: true,
                 post_tool: [
                   fn payload ->
                     {:ok, %{payload | result: %{reply: "rewritten-by-hook"}}}
                   end
                 ]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["reply"] == "rewritten-by-hook"
    assert Process.get(:tool_called_with) == %{"text" => "hello"}
  end

  test "pre_mcp hooks can block discovery before the server is contacted" do
    assert {:error, {:mcp_hook_blocked, "github", {:hook_denied, :pre_mcp, "discovery_blocked"}}} =
             Synaptic.Tools.chat([%{role: "user", content: "hi"}],
               adapter: CaptureAdapter,
               mcp: [%{name: "github", adapter: MCPAdapter, transport: :http}],
               hooks: [
                 enabled: true,
                 pre_mcp: [
                   fn payload ->
                     if payload.action == :discover do
                       {:deny, "discovery_blocked"}
                     else
                       :ok
                     end
                   end
                 ]
               ]
             )

    refute Process.get({MCPAdapter, :discover_calls})
  end

  test "pre_mcp hooks can rewrite MCP tool arguments before adapter invocation" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, ~s({"query":"bugs"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat([%{role: "user", content: "hi"}],
               adapter: ToolLoopAdapter,
               mcp: [%{name: "github", adapter: MCPAdapter, transport: :http}],
               hooks: [
                 enabled: true,
                 pre_mcp: [
                   fn payload ->
                     if payload.action == :call_tool do
                       {:ok, %{payload | args: %{"query" => "security"}}}
                     else
                       :ok
                     end
                   end
                 ]
               ]
             )

    assert Process.get({MCPAdapter, :last_call_tool}) ==
             {"github", "search_issues", %{"query" => "security"}}
  end

  test "managed_only ignores per-call hooks and only applies managed global hooks" do
    Application.put_env(:synaptic, Synaptic.PolicyHooks,
      enabled: true,
      managed_only: true,
      pre_prompt: [
        fn payload ->
          updated_messages =
            Enum.map(payload.messages, fn
              %{role: "user", content: content} = message ->
                %{message | content: content <> "\n[managed]"}

              message ->
                message
            end)

          {:ok, %{payload | messages: updated_messages}}
        end
      ]
    )

    Process.put(:test_pid, self())

    assert {:ok, "raw-output"} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               hooks: [
                 enabled: true,
                 pre_prompt: [
                   fn payload ->
                     {:ok, %{payload | messages: [%{role: "user", content: "per-call"}]}}
                   end
                 ]
               ]
             )

    assert_receive {:captured_messages, [%{content: content}]}, 1_000
    assert content =~ "[managed]"
    refute content == "per-call"
  end

  test "per-call hooks false disables global hooks when managed_only is off" do
    Application.put_env(:synaptic, Synaptic.PolicyHooks,
      enabled: true,
      pre_prompt: [
        fn payload ->
          {:ok, %{payload | messages: [%{role: "user", content: "global-hook"}]}}
        end
      ]
    )

    Process.put(:test_pid, self())

    assert {:ok, "raw-output"} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               hooks: false
             )

    assert_receive {:captured_messages, [%{content: content}]}, 1_000
    assert content == "Email me at jane@example.com"
  end

  defp echo_tool do
    %Synaptic.Tools.Tool{
      name: "echo",
      description: "Echoes text",
      schema: %{
        type: "object",
        properties: %{text: %{type: "string"}},
        required: ["text"]
      },
      handler: fn args ->
        Process.put(:tool_called_with, args)
        %{reply: Map.fetch!(args, "text")}
      end
    }
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      :test_pid,
      :tool_called_with,
      :last_tool_message,
      :next_tool_name,
      :next_tool_args_json,
      {ToolLoopAdapter, :stage},
      {MCPAdapter, :discover_calls},
      {MCPAdapter, :last_call_tool}
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
