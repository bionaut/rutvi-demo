defmodule Synaptic.EgressPolicyTest do
  use ExUnit.Case, async: true

  alias Synaptic.OutboundHTTP
  alias Synaptic.Tools.OpenAI

  test "blocks outbound chat requests to localhost when egress is enabled by default posture" do
    bypass = Bypass.open()

    assert {:error, {:egress_blocked, detail}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: OpenAI,
               endpoint: "http://localhost:#{bypass.port}/chat",
               api_key: "test-key",
               finch: Synaptic.Finch,
               egress: [enabled: true]
             )

    assert detail.code == :localhost_blocked
  end

  test "allows explicitly allowlisted localhost endpoints" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/chat", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, ~s({"choices":[{"message":{"content":"hello"}}]}))
    end)

    assert {:ok, "hello"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: OpenAI,
               endpoint: "http://localhost:#{bypass.port}/chat",
               api_key: "test-key",
               finch: Synaptic.Finch,
               egress: [
                 enabled: true,
                 openai: [
                   allow_hosts: ["localhost"],
                   allow_localhost: true,
                   allow_schemes: ["http"]
                 ]
               ]
             )
  end

  test "blocks disallowed response MIME types even after host allowlisting" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/chat", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, "plain text")
    end)

    assert {:error, {:egress_blocked, detail}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: OpenAI,
               endpoint: "http://localhost:#{bypass.port}/chat",
               api_key: "test-key",
               finch: Synaptic.Finch,
               egress: [
                 enabled: true,
                 openai: [
                   allow_hosts: ["localhost"],
                   allow_localhost: true,
                   allow_schemes: ["http"]
                 ]
               ]
             )

    assert detail.code == :mime_not_allowed
  end

  test "halts streamed responses when their cumulative body exceeds the byte cap" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/stream", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, "1234")
      {:ok, conn} = Plug.Conn.chunk(conn, "5678")
      conn
    end)

    assert {:error, {:egress_blocked, detail}} =
             OutboundHTTP.stream_while(
               :post,
               "http://localhost:#{bypass.port}/stream",
               [],
               "",
               "",
               fn
                 {:data, data}, acc -> {:cont, acc <> data}
                 _event, acc -> {:cont, acc}
               end,
               finch: Synaptic.Finch,
               policy_opts: [
                 egress: [
                   enabled: true,
                   openai: [
                     allow_hosts: ["localhost"],
                     allow_localhost: true,
                     allow_schemes: ["http"],
                     max_response_bytes: 5
                   ]
                 ]
               ],
               context: %{surface: :openai}
             )

    assert detail.code == :response_too_large
    assert detail.details.bytes == 8
  end

  test "halts ordinary responses while receiving a body above the byte cap" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/chat", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, ~s({"choices":[{"message":{"content":"too large"}}]}))
    end)

    assert {:error, {:egress_blocked, detail}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: OpenAI,
               endpoint: "http://localhost:#{bypass.port}/chat",
               api_key: "test-key",
               finch: Synaptic.Finch,
               egress: [
                 enabled: true,
                 openai: [
                   allow_hosts: ["localhost"],
                   allow_localhost: true,
                   allow_schemes: ["http"],
                   max_response_bytes: 10
                 ]
               ]
             )

    assert detail.code == :response_too_large
  end

  test "blocks an allowlisted hostname when DNS resolves it to a non-public address" do
    resolver = fn "allowed.example" -> {:ok, [{10, 1, 2, 3}]} end

    assert {:error, {:egress_blocked, detail}} =
             Synaptic.EgressPolicy.authorize_request(
               :mcp,
               :post,
               "https://allowed.example/rpc",
               egress: [
                 enabled: true,
                 mcp: [allow_hosts: ["allowed.example"], dns_resolver: resolver]
               ]
             )

    assert detail.code == :private_network_blocked
  end

  test "allows an allowlisted hostname when DNS resolves only public addresses" do
    resolver = fn "allowed.example" -> {:ok, [{93, 184, 216, 34}]} end

    assert :ok =
             Synaptic.EgressPolicy.authorize_request(
               :mcp,
               :post,
               "https://allowed.example/rpc",
               egress: [
                 enabled: true,
                 mcp: [allow_hosts: ["allowed.example"], dns_resolver: resolver]
               ]
             )
  end

  test "fails closed when a custom DNS resolver returns malformed data" do
    assert {:error, {:egress_blocked, detail}} =
             Synaptic.EgressPolicy.authorize_request(
               :mcp,
               :post,
               "https://allowed.example/rpc",
               egress: [
                 enabled: true,
                 mcp: [
                   allow_hosts: ["allowed.example"],
                   dns_resolver: fn _host -> {:ok, [:not_an_address]} end
                 ]
               ]
             )

    assert detail.code == :host_resolution_failed
  end
end
