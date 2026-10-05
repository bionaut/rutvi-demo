defmodule Synaptic.ToolPolicyTest do
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

  defmodule MCPAdapter do
    use Synaptic.MCP.Adapter

    @impl true
    def discover(_connection, _opts) do
      {:ok,
       %Synaptic.MCP.Discovery{
         tools: [
           %{
             name: "search_issues",
             description: "Searches issues",
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

  @messages [%{role: "user", content: "ping"}]

  setup do
    original_policy = Application.get_env(:synaptic, Synaptic.ToolPolicy)

    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.ToolPolicy, original_policy)
      reset_process_state()
    end)

    :ok
  end

  test "tool policy is off by default even for tools marked needs_approval" do
    tool = approval_tool()

    Process.put(:next_tool_name, "send_email")
    Process.put(:next_tool_args_json, ~s({"email":"jane@example.com"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: ToolLoopAdapter,
               tools: [tool]
             )

    assert Process.get(:tool_called_with) == %{"email" => "jane@example.com"}
  end

  test "policy ask blocks the tool and returns approval_required when no resolver is configured" do
    tool = approval_tool()

    Process.put(:next_tool_name, "send_email")
    Process.put(:next_tool_args_json, ~s({"email":"jane@example.com"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: ToolLoopAdapter,
               tools: [tool],
               policy: [enabled: true]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "approval_required"
    assert payload["decision"] == "ask"
    assert payload["tool"] == "send_email"
    refute Process.get(:tool_called_with)
  end

  test "approval resolver can auto-approve and callers can inspect decision traces" do
    tool = approval_tool()
    parent = self()

    Process.put(:next_tool_name, "send_email")
    Process.put(:next_tool_args_json, ~s({"email":"jane@example.com"}))

    assert {:ok, "final", %{policy_decisions: [decision]}} =
             Synaptic.Tools.chat(@messages,
               adapter: ToolLoopAdapter,
               tools: [tool],
               policy: [
                 enabled: true,
                 return_decisions: true,
                 approval_resolver: fn request ->
                   send(
                     parent,
                     {:approval_request, request.tool, request.metadata.needs_approval}
                   )

                   :approve
                 end
               ]
             )

    assert_receive {:approval_request, "send_email", true}, 1_000
    assert Process.get(:tool_called_with) == %{"email" => "jane@example.com"}
    assert decision.decision == :allow
    assert decision.approval.decision == :allow
    assert decision.metadata.needs_approval == true
  end

  test "deny wins over allow when multiple rules match" do
    tool = %Synaptic.Tools.Tool{
      name: "delete_user",
      description: "deletes a user",
      schema: %{
        type: "object",
        properties: %{id: %{type: "string"}},
        required: ["id"]
      },
      destructive: true,
      handler: fn args ->
        Process.put(:tool_called_with, args)
        %{status: "deleted"}
      end
    }

    Process.put(:next_tool_name, "delete_user")
    Process.put(:next_tool_args_json, ~s({"id":"user_1"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: ToolLoopAdapter,
               tools: [tool],
               policy: [
                 enabled: true,
                 rules: [
                   [decision: :allow, tools: :all, reason: "local_tools_allowed"],
                   [decision: :deny, destructive: true, reason: "no_destructive_tools"]
                 ]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "policy_denied"
    assert payload["reason"] == "no_destructive_tools"
    refute Process.get(:tool_called_with)
  end

  test "policy can deny MCP tool calls by server before adapter invocation" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, ~s({"query":"bugs"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: ToolLoopAdapter,
               mcp: [%{name: "github", adapter: MCPAdapter, transport: :http}],
               policy: [
                 enabled: true,
                 rules: [[decision: :deny, server: "github", reason: "mcp_server_blocked"]]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "policy_denied"
    assert payload["server"] == "github"
    assert payload["tool"] == "search_issues"
    refute Process.get({MCPAdapter, :last_call_tool})
  end

  test "policy can match MCP permissions by fully qualified tool name" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, ~s({"query":"bugs"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: ToolLoopAdapter,
               mcp: [%{name: "github", adapter: MCPAdapter, transport: :http}],
               policy: [
                 enabled: true,
                 rules: [
                   [
                     decision: :deny,
                     tool: "github__search_issues",
                     reason: "qualified_tool_blocked"
                   ]
                 ]
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)

    assert payload["code"] == "policy_denied"
    assert payload["reason"] == "qualified_tool_blocked"
    assert payload["server"] == "github"
    assert payload["tool"] == "search_issues"
    refute Process.get({MCPAdapter, :last_call_tool})
  end

  test "per-call policy false overrides global enabled policy" do
    Application.put_env(:synaptic, Synaptic.ToolPolicy,
      enabled: true,
      rules: [[decision: :ask, tools: :all, reason: "global_gate"]]
    )

    tool = approval_tool()

    Process.put(:next_tool_name, "send_email")
    Process.put(:next_tool_args_json, ~s({"email":"jane@example.com"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: ToolLoopAdapter,
               tools: [tool],
               policy: false
             )

    assert Process.get(:tool_called_with) == %{"email" => "jane@example.com"}
  end

  defp approval_tool do
    %Synaptic.Tools.Tool{
      name: "send_email",
      description: "sends an email",
      schema: %{
        type: "object",
        properties: %{email: %{type: "string"}},
        required: ["email"]
      },
      needs_approval: true,
      data_class: :pii,
      handler: fn args ->
        Process.put(:tool_called_with, args)
        %{status: "sent"}
      end
    }
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      {ToolLoopAdapter, :stage},
      {MCPAdapter, :last_call_tool},
      :tool_called_with,
      :last_tool_message,
      :next_tool_name,
      :next_tool_args_json
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
