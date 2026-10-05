defmodule Synaptic.ConnectorGatewayTest do
  use ExUnit.Case, async: true

  alias Synaptic.ConnectorGateway
  alias Synaptic.MCP
  alias Synaptic.MCP.Adapters.HTTP
  alias Synaptic.MCP.Connection

  setup do
    on_exit(fn ->
      case :ets.whereis(:synaptic_connector_gateway) do
        :undefined -> :ok
        _table -> :ets.delete_all_objects(:synaptic_connector_gateway)
      end
    end)

    :ok
  end

  test "blocks passthrough credential headers on MCP requests" do
    bypass = Bypass.open()

    connection = %Connection{
      id: "mcp_1",
      name: "github",
      transport: :http,
      adapter: HTTP,
      adapter_opts: [
        base_url: "http://localhost:#{bypass.port}/mcp",
        finch: Synaptic.Finch,
        headers: [{"authorization", "Bearer raw-token"}]
      ],
      metadata: %{managed: true}
    }

    assert {:error, {:connector_gateway_blocked, detail}} =
             MCP.discover(
               connection,
               egress: [
                 enabled: true,
                 mcp: [allow_hosts: ["localhost"], allow_localhost: true, allow_schemes: ["http"]]
               ],
               connector_gateway: [enabled: true]
             )

    assert detail.code == :credential_passthrough_forbidden
  end

  test "adds session-binding headers to managed MCP traffic" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-synaptic-session-binding") != []
      assert Plug.Conn.get_req_header(conn, "x-synaptic-connector") |> List.first() =~ "mcp"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      current = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

      response =
        case {current, payload["method"]} do
          {1, "initialize"} ->
            %{
              "jsonrpc" => "2.0",
              "id" => payload["id"],
              "result" => %{
                "protocolVersion" => "2025-03-26",
                "serverInfo" => %{"name" => "test-server", "version" => "1.0.0"},
                "capabilities" => %{}
              }
            }

          {2, "notifications/initialized"} ->
            nil

          {3, "tools/list"} ->
            %{"jsonrpc" => "2.0", "id" => payload["id"], "result" => %{"tools" => []}}

          {4, "resources/list"} ->
            %{
              "jsonrpc" => "2.0",
              "id" => payload["id"],
              "error" => %{"code" => -32_601, "message" => "Method not found"}
            }
        end

      if response do
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> maybe_put_session_header(current)
        |> Plug.Conn.resp(200, Jason.encode!(response))
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    connection = %Connection{
      id: "mcp_1",
      name: "github",
      transport: :http,
      adapter: HTTP,
      adapter_opts: [base_url: "http://localhost:#{bypass.port}/mcp", finch: Synaptic.Finch],
      metadata: %{managed: true}
    }

    assert {:ok, discovery} =
             MCP.discover(
               connection,
               run_id: "gateway-run",
               egress: [
                 enabled: true,
                 mcp: [allow_hosts: ["localhost"], allow_localhost: true, allow_schemes: ["http"]]
               ],
               connector_gateway: [
                 enabled: true,
                 session_binding: [enabled: true, require_run_id: true]
               ]
             )

    refute discovery.resources_supported?
  end

  test "rate-limits repeated connector requests" do
    opts = [
      connector_gateway: [
        enabled: true,
        rate_limits: [[connector: :mcp, max_calls: 1, window_ms: 60_000]]
      ]
    ]

    assert {:ok, _headers} =
             ConnectorGateway.preflight(
               :mcp,
               %{url: "https://example.com", connector: :mcp},
               opts
             )

    assert {:error, {:connector_gateway_blocked, detail}} =
             ConnectorGateway.preflight(
               :mcp,
               %{url: "https://example.com", connector: :mcp},
               opts
             )

    assert detail.code == :gateway_rate_limit_exceeded
  end

  test "treats secure WebSocket transport as TLS when HTTPS is required" do
    assert {:ok, _headers} =
             ConnectorGateway.preflight(
               :voice,
               %{url: "wss://generativelanguage.googleapis.com/ws", connector: :gemini},
               connector_gateway: [enabled: true, tls: [require_https: true]]
             )
  end

  test "rejects caller-supplied session-binding headers" do
    assert {:error, {:connector_gateway_blocked, detail}} =
             ConnectorGateway.preflight(
               :mcp,
               %{
                 url: "https://example.com/mcp",
                 connector: :mcp,
                 passthrough_headers: [{"x-synaptic-session-binding", "attacker-value"}]
               },
               connector_gateway: [enabled: true, session_binding: [enabled: true]]
             )

    assert detail.code == :managed_header_passthrough_forbidden
  end

  defp maybe_put_session_header(conn, 1 = _init_request) do
    Plug.Conn.put_resp_header(conn, "mcp-session-id", "session-123")
  end

  defp maybe_put_session_header(conn, _), do: conn
end
