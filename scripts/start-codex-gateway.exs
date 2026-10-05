token_file = System.fetch_env!("RUTVI_CODEX_GATEWAY_TOKEN_FILE")
token = token_file |> File.read!() |> String.trim()

if byte_size(token) < 64, do: raise("Codex gateway token must contain at least 64 characters")

if not String.starts_with?(System.get_env("RUTVI_CODEX_GATEWAY_BIND", "127.0.0.1"), "127.") do
  raise "Codex gateway may only bind to IPv4 loopback"
end

bind_address = System.get_env("RUTVI_CODEX_GATEWAY_BIND", "127.0.0.1")
{:ok, bind} = :inet.parse_address(String.to_charlist(bind_address))
port = String.to_integer(System.get_env("RUTVI_CODEX_GATEWAY_PORT", "4041"))

Application.ensure_all_started(:plug_cowboy)
Application.ensure_all_started(:inets)
Application.ensure_all_started(:ssl)
Application.put_env(:rutvi_exercise, :codex_gateway_token, token)
{:ok, _limiter} = RutviExercise.CodexGateway.Limiter.start_link()

{:ok, _server} =
  Plug.Cowboy.http(RutviExercise.CodexGateway.Router, [],
    ip: bind,
    port: port,
    ref: RutviCodexGateway,
    transport_options: [num_acceptors: 8, max_connections: 16]
  )

IO.puts("Codex gateway listening on 127.0.0.1:#{port}; model=gpt-6.1-sol; reasoning=medium")
Process.sleep(:infinity)
