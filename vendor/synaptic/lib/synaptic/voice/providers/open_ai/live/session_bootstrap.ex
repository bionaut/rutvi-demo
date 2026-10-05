defmodule Synaptic.Voice.Providers.OpenAI.Live.SessionBootstrap do
  @moduledoc """
  Creates a GPT-Live WebRTC session using a browser SDP offer. Unlike Realtime,
  Live returns an SDP answer, not an ephemeral client secret.
  """

  alias Synaptic.{OutboundHTTP, Voice.Providers.OpenAI}

  @endpoint "https://api.openai.com/v1/live/sessions"

  def create_browser_bootstrap(opts \\ []) do
    with :ok <- validate_sdp(opts[:sdp]),
         {:ok, api_key} <- api_key(opts) do
      config = OpenAI.config(opts)
      model = opts[:model] || config[:live_model] || "gpt-live-1"
      voice = opts[:voice] || config[:live_voice] || "marin"

      session = %{
        model: model,
        instructions:
          opts[:instructions] || "Be helpful and concise. Delegate task work to the backend.",
        audio: %{output: %{voice: voice}},
        delegation: %{type: "client"},
        input: opts[:input] || [],
        store: false
      }

      body = Jason.encode!(%{session: session, transport: %{type: "webrtc", sdp: opts[:sdp]}})

      headers = [
        {"content-type", "application/json"},
        {"authorization", "Bearer " <> api_key}
      ]

      # Creation is billable and has no application idempotency key. Do not retry it.
      case OutboundHTTP.request(
             :post,
             opts[:endpoint] || config[:live_endpoint] || @endpoint,
             headers,
             body,
             finch: OpenAI.finch(opts),
             policy_opts: opts,
             context: %{surface: :voice, connector: :openai, action: :live_session_bootstrap},
             request_options: [receive_timeout: opts[:receive_timeout] || 15_000]
           ) do
        {:ok, %Finch.Response{status: 201, body: response}} ->
          decode_bootstrap(response, model, voice)

        {:ok, %Finch.Response{status: status, body: response}} ->
          {:error, {:upstream_error, status, response}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp validate_sdp(sdp) when is_binary(sdp) and byte_size(sdp) in 1..65_536 do
    if String.trim(sdp) == "", do: {:error, :missing_sdp_offer}, else: :ok
  end

  defp validate_sdp(_), do: {:error, :missing_sdp_offer}

  defp api_key(opts) do
    case opts[:api_key] || OpenAI.config(opts)[:api_key] || System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, :missing_openai_api_key}
    end
  end

  defp decode_bootstrap(response, model, voice) do
    case Jason.decode(response) do
      {:ok, %{"session" => %{"id" => id}, "transport" => %{"type" => "webrtc", "sdp" => sdp}}}
      when is_binary(id) and is_binary(sdp) and byte_size(sdp) > 0 ->
        {:ok,
         %{
           provider: :openai,
           experience: :live,
           type: :webrtc,
           session_id: id,
           model: model,
           voice: voice,
           sdp: sdp
         }}

      _ ->
        {:error, :invalid_live_bootstrap}
    end
  end
end
