defmodule RutviExercise.Models.RemoteCodex do
  @moduledoc "Authenticated transport to the developer's loopback Codex gateway."

  @max_body_bytes 262_144
  @request_overhead_ms 5_000
  @max_timeout_ms 115_000
  @allowed_options [:timeout_ms, :http_client]

  @spec generate(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def generate(request, opts \\ [])

  def generate(request, opts) when is_map(request) and is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, body} <- request_body(request),
         {:ok, url, token} <- gateway_config(),
         result <- post(url, token, body, opts),
         {:ok, response} <- result do
      decode_response(response)
    end
  end

  def generate(_request, _opts), do: {:error, error(:invalid_request, false)}

  defp request_body(request) do
    messages = Map.get(request, :messages) || Map.get(request, "messages")
    schema = Map.get(request, :output_schema) || Map.get(request, "output_schema")

    if valid_messages?(messages) and is_map(schema) and map_size(schema) > 0 do
      case Jason.encode(%{"messages" => messages, "output_schema" => schema}) do
        {:ok, body} when byte_size(body) <= @max_body_bytes -> {:ok, body}
        {:ok, _body} -> {:error, error(:request_too_large, false)}
        {:error, _reason} -> {:error, error(:invalid_request, false)}
      end
    else
      {:error, error(:invalid_request, false)}
    end
  end

  defp valid_messages?(messages) when is_list(messages) and messages != [] do
    Enum.all?(messages, fn message ->
      if is_map(message) do
        role = Map.get(message, :role) || Map.get(message, "role")
        content = Map.get(message, :content) || Map.get(message, "content")
        role in [:system, :user, :assistant, "system", "user", "assistant"] and is_binary(content)
      else
        false
      end
    end)
  end

  defp valid_messages?(_), do: false

  defp validate_options(opts) do
    timeout = Keyword.get(opts, :timeout_ms, 90_000)

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @allowed_options)) and
         is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms do
      :ok
    else
      {:error, error(:invalid_options, false)}
    end
  end

  defp gateway_config do
    url = System.get_env("RUTVI_CODEX_GATEWAY_URL")

    token =
      case System.get_env("RUTVI_CODEX_GATEWAY_TOKEN") do
        nil -> nil
        value -> String.trim_trailing(value, "\n") |> String.trim_trailing("\r")
      end

    if is_binary(url) and String.starts_with?(url, "http://") and is_binary(token) and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, token) do
      {:ok, String.trim_trailing(url, "/"), token}
    else
      {:error, error(:gateway_unavailable, false)}
    end
  end

  defp post(url, token, body, opts) do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         true <- Code.ensure_loaded?(:httpc) do
      do_post(url, token, body, opts)
    else
      _ -> {:error, error(:http_client_unavailable, false)}
    end
  rescue
    _ -> {:error, error(:gateway_transport_failure, false)}
  catch
    _, _ -> {:error, error(:gateway_transport_failure, false)}
  end

  defp do_post(url, token, body, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 90_000)
    request_timeout = timeout + @request_overhead_ms
    client = Keyword.get(opts, :http_client, &:httpc.request/4)

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"accept", ~c"application/json"}
    ]

    request = {String.to_charlist(url <> "/v1/generate"), headers, ~c"application/json", body}

    case client.(:post, request, [{:timeout, request_timeout}, {:connect_timeout, 3_000}], [
           {:body_format, :binary}
         ]) do
      {:ok, {{_version, status, _reason}, _headers, response_body}}
      when status in 200..599 and is_binary(response_body) ->
        {:ok, {status, response_body}}

      {:error, :timeout} ->
        {:error, error(:provider_timeout, true)}

      {:error, _reason} ->
        {:error, error(:gateway_unavailable, true, %{reason: "connection_failed"})}

      _ ->
        {:error, error(:gateway_protocol_error, true)}
    end
  end

  defp decode_response({200, body}) do
    with {:ok, response} <- Jason.decode(body),
         %{"output" => output, "model" => "gpt-6-luna", "reasoning_effort" => "low"} =
           response <- response,
         true <- is_map(output) do
      {:ok,
       %{
         output: output,
         model: "gpt-6-luna",
         reasoning_effort: "low",
         usage: Map.get(response, "usage")
       }}
    else
      _ -> {:error, error(:gateway_protocol_error, true)}
    end
  end

  defp decode_response({status, body}) do
    with {:ok, %{"error" => error_map}} <- Jason.decode(body),
         true <- is_map(error_map) do
      {:error,
       %{
         code: safe_code(error_map["code"]),
         message: safe_message(error_map["message"]),
         retryable: error_map["retryable"] == true,
         details: if(is_map(error_map["details"]), do: error_map["details"], else: %{})
       }}
    else
      _ ->
        {:error,
         error(if(status == 401, do: :gateway_unauthorized, else: :gateway_error), status >= 500)}
    end
  end

  defp safe_code(code) when is_binary(code) do
    case code do
      "provider_timeout" -> :provider_timeout
      "model_unavailable" -> :model_unavailable
      "provider_error" -> :provider_error
      "invalid_request" -> :invalid_request
      "invalid_output_schema" -> :invalid_output_schema
      "schema_validation_failed" -> :schema_validation_failed
      "invalid_model_output" -> :invalid_model_output
      "provider_unavailable" -> :provider_unavailable
      "busy" -> :busy
      _ -> :gateway_error
    end
  end

  defp safe_code(_), do: :gateway_error
  defp safe_message(message) when is_binary(message), do: String.slice(message, 0, 500)
  defp safe_message(_), do: "The local Codex gateway returned an error."

  defp error(code, retryable, details \\ %{}) do
    %{
      code: code,
      message: "The local Codex gateway request failed.",
      retryable: retryable,
      details: details
    }
  end
end
