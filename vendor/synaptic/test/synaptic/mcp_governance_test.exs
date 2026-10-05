defmodule Synaptic.MCPGovernanceTest do
  use ExUnit.Case

  alias Synaptic.MCP.Discovery

  defmodule CaptureAdapter do
    def chat(_messages, opts), do: {:ok, {:capture, opts}}
  end

  defmodule MCPAdapter do
    use Synaptic.MCP.Adapter

    @impl true
    def discover(connection, _opts) do
      Process.put({__MODULE__, :last_discover}, connection.name)

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
    def call_tool(_connection, _remote_name, _args, _opts), do: {:ok, %{}}

    @impl true
    def list_resources(_connection, _opts), do: {:ok, []}

    @impl true
    def read_resource(_connection, _uri, _opts), do: {:ok, %{"contents" => []}}
  end

  @messages [%{role: "user", content: "ping"}]

  setup do
    original_mcp = Application.get_env(:synaptic, Synaptic.MCP)
    original_governance = Application.get_env(:synaptic, Synaptic.MCPGovernance)

    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.MCP, original_mcp)
      restore_env(Synaptic.MCPGovernance, original_governance)
      reset_process_state()
    end)

    :ok
  end

  test "MCP governance is off by default" do
    assert {:ok, {:capture, opts}} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               mcp: [%{name: "github", adapter: MCPAdapter, transport: :http}]
             )

    tool_names =
      Enum.map(opts[:tools] || [], fn spec ->
        get_in(spec, [:function, :name])
      end)

    assert "github__search_issues" in tool_names
  end

  test "governance can deny servers by name before discovery" do
    assert {:error, {:mcp_governance_denied, "github", :server_name_blocked}} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               mcp: [%{name: "github", adapter: MCPAdapter, transport: :http}],
               mcp_governance: [enabled: true, deny_servers: ["github"]]
             )

    refute Process.get({MCPAdapter, :last_discover})
  end

  test "governance can deny servers by URL pattern" do
    assert {:error, {:mcp_governance_denied, "github", :server_url_blocked}} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               mcp: [
                 %{
                   name: "github",
                   adapter: MCPAdapter,
                   transport: :http,
                   base_url: "https://api.github.com"
                 }
               ],
               mcp_governance: [enabled: true, deny_url_patterns: ["github.com"]]
             )
  end

  test "governance can deny servers by command pattern" do
    assert {:error, {:mcp_governance_denied, "filesystem", :server_command_blocked}} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               mcp: [
                 %{
                   name: "filesystem",
                   adapter: MCPAdapter,
                   transport: :stdio,
                   command: "npx -y @modelcontextprotocol/server-filesystem"
                 }
               ],
               mcp_governance: [enabled: true, deny_command_patterns: ["server-filesystem"]]
             )
  end

  test "managed_only blocks inline servers but allows configured servers" do
    Application.put_env(:synaptic, Synaptic.MCP,
      servers: [
        github: [
          transport: :http,
          adapter: MCPAdapter,
          base_url: "https://api.github.com"
        ]
      ]
    )

    assert {:error, {:mcp_governance_denied, "github", :unmanaged_server}} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               mcp: [
                 %{
                   name: "github",
                   adapter: MCPAdapter,
                   transport: :http,
                   base_url: "https://api.github.com"
                 }
               ],
               mcp_governance: [enabled: true, managed_only: true]
             )

    assert {:ok, {:capture, opts}} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               mcp: [:github],
               mcp_governance: [enabled: true, managed_only: true]
             )

    tool_names =
      Enum.map(opts[:tools] || [], fn spec ->
        get_in(spec, [:function, :name])
      end)

    assert "github__search_issues" in tool_names
  end

  test "global managed_only governance ignores per-call disable attempts" do
    Application.put_env(:synaptic, Synaptic.MCP,
      servers: [
        github: [
          transport: :http,
          adapter: MCPAdapter,
          base_url: "https://api.github.com"
        ]
      ]
    )

    Application.put_env(:synaptic, Synaptic.MCPGovernance,
      enabled: true,
      managed_only: true,
      deny_servers: ["github"]
    )

    assert {:error, {:mcp_governance_denied, "github", :server_name_blocked}} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               mcp: [:github],
               mcp_governance: false
             )
  end

  test "per-call governance false disables global governance when managed_only is off" do
    Application.put_env(:synaptic, Synaptic.MCPGovernance,
      enabled: true,
      deny_servers: ["github"]
    )

    assert {:ok, {:capture, opts}} =
             Synaptic.Tools.chat(@messages,
               adapter: CaptureAdapter,
               mcp: [%{name: "github", adapter: MCPAdapter, transport: :http}],
               mcp_governance: false
             )

    tool_names =
      Enum.map(opts[:tools] || [], fn spec ->
        get_in(spec, [:function, :name])
      end)

    assert "github__search_issues" in tool_names
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    Process.delete({MCPAdapter, :last_discover})
  end
end
