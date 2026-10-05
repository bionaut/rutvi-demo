defmodule Synaptic.OutboundHTTP do
  @moduledoc false

  alias Synaptic.{ConnectorGateway, EgressPolicy}

  def preflight(method, url, opts \\ []) do
    policy_opts = Keyword.get(opts, :policy_opts, [])
    context = Map.new(Keyword.get(opts, :context, %{}))

    with :ok <-
           EgressPolicy.authorize_request(surface(context), method, url, policy_opts, context),
         {:ok, gateway_headers} <-
           ConnectorGateway.preflight(
             surface(context),
             gateway_context(context, method, url),
             policy_opts
           ) do
      {:ok, gateway_headers}
    end
  end

  def request(method, url, headers, body, opts \\ []) do
    policy_opts = Keyword.get(opts, :policy_opts, [])
    context = Map.new(Keyword.get(opts, :context, %{}))

    initial = %{status: nil, headers: [], chunks: []}

    with {:ok, response_parts} <-
           stream_while(
             method,
             url,
             headers,
             body,
             initial,
             &collect_response/2,
             opts
           ),
         response <- %Finch.Response{
           status: response_parts.status,
           headers: response_parts.headers,
           body: response_parts.chunks |> Enum.reverse() |> IO.iodata_to_binary()
         },
         :ok <-
           EgressPolicy.validate_response(surface(context), url, response, policy_opts, context) do
      {:ok, response}
    else
      {:error, {:egress_blocked, _detail}} = error ->
        error

      {:error, {:connector_gateway_blocked, _detail}} = error ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_response({:status, status}, acc), do: {:cont, %{acc | status: status}}
  defp collect_response({:headers, headers}, acc), do: {:cont, %{acc | headers: headers}}
  defp collect_response({:data, data}, acc), do: {:cont, %{acc | chunks: [data | acc.chunks]}}
  defp collect_response(_event, acc), do: {:cont, acc}

  def stream_while(method, url, headers, body, acc, fun, opts \\ []) when is_function(fun, 2) do
    finch = Keyword.fetch!(opts, :finch)
    request_opts = Keyword.get(opts, :request_options, [])
    policy_opts = Keyword.get(opts, :policy_opts, [])
    context = Map.new(Keyword.get(opts, :context, %{}))

    with {:ok, gateway_headers} <-
           preflight(method, url, policy_opts: policy_opts, context: context) do
      request = Finch.build(method, url, headers ++ gateway_headers, body)

      try do
        Finch.stream_while(
          request,
          finch,
          {acc, nil, 0},
          fn
            {:status, status} = event, {inner_acc, _status, bytes} ->
              wrap_stream_result(fun.(event, inner_acc), status, bytes)

            {:headers, resp_headers} = event, {inner_acc, status, bytes} ->
              case EgressPolicy.validate_stream_response(
                     surface(context),
                     url,
                     status || 200,
                     resp_headers,
                     policy_opts,
                     context
                   ) do
                :ok -> wrap_stream_result(fun.(event, inner_acc), status, bytes)
                {:error, {:egress_blocked, detail}} -> throw({:egress_blocked, detail})
              end

            {:data, data} = event, {inner_acc, status, bytes} when is_binary(data) ->
              total_bytes = bytes + byte_size(data)

              case EgressPolicy.validate_stream_body_size(
                     surface(context),
                     url,
                     total_bytes,
                     policy_opts,
                     context
                   ) do
                :ok -> wrap_stream_result(fun.(event, inner_acc), status, total_bytes)
                {:error, {:egress_blocked, detail}} -> throw({:egress_blocked, detail})
              end

            event, {inner_acc, status, bytes} ->
              wrap_stream_result(fun.(event, inner_acc), status, bytes)
          end,
          request_opts
        )
        |> unwrap_stream_result()
      catch
        {:egress_blocked, detail} ->
          {:error, {:egress_blocked, detail}}
      end
    else
      {:error, {:egress_blocked, _detail}} = error ->
        error

      {:error, {:connector_gateway_blocked, _detail}} = error ->
        error
    end
  end

  defp wrap_stream_result({:cont, acc}, status, bytes), do: {:cont, {acc, status, bytes}}
  defp wrap_stream_result({:halt, acc}, status, bytes), do: {:halt, {acc, status, bytes}}

  defp unwrap_stream_result({:ok, {acc, _status, _bytes}}), do: {:ok, acc}
  defp unwrap_stream_result({:error, reason, {_acc, _status, _bytes}}), do: {:error, reason}
  defp unwrap_stream_result(other), do: other

  defp gateway_context(context, method, url) do
    Map.merge(context, %{
      method: method,
      url: url,
      host: URI.parse(to_string(url)).host
    })
  end

  defp surface(context), do: Map.get(context, :surface, :openai)
end
