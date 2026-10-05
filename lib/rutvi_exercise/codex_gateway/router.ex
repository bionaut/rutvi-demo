defmodule RutviExercise.CodexGateway.Router do
  @moduledoc false
  use Plug.Router

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    length: 262_144
  )

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_json(conn, 200, %{status: "ok"})
  end

  post "/v1/generate" do
    with :ok <- authenticate(conn),
         {:ok, messages, schema} <- validate_body(conn.body_params),
         :ok <- RutviExercise.CodexGateway.Limiter.acquire() do
      result =
        try do
          scratch =
            Path.join(System.tmp_dir!(), "rutvi-gateway-#{System.unique_integer([:positive])}")

          try do
            RutviExercise.Models.Codex.generate(
              %{messages: messages, output_schema: schema},
              timeout_ms: 90_000,
              scratch_dir: scratch
            )
          after
            File.rm_rf(scratch)
          end
        after
          RutviExercise.CodexGateway.Limiter.release()
        end

      respond_result(conn, result)
    else
      {:error, :unauthorized} ->
        send_json(conn, 401, %{
          error: %{code: "unauthorized", message: "Unauthorized.", retryable: false}
        })

      {:error, :busy} ->
        send_json(conn, 503, %{
          error: %{code: "busy", message: "The local model gateway is busy.", retryable: true}
        })

      {:error, reason} ->
        send_json(conn, 400, %{
          error: %{code: Atom.to_string(reason), message: "Invalid request.", retryable: false}
        })
    end
  end

  match _ do
    send_json(conn, 404, %{error: %{code: "not_found", message: "Not found.", retryable: false}})
  end

  defp authenticate(conn) do
    expected = Application.fetch_env!(:rutvi_exercise, :codex_gateway_token)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> supplied] ->
        if byte_size(supplied) == byte_size(expected) and :crypto.hash_equals(supplied, expected),
          do: :ok,
          else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp validate_body(%{"messages" => messages, "output_schema" => schema} = body)
       when map_size(body) == 2 and is_list(messages) and messages != [] and is_map(schema) and
              map_size(schema) > 0 do
    if Enum.all?(messages, fn message ->
         is_map(message) and
           Map.get(message, "role") in ["system", "user", "assistant"] and
           is_binary(Map.get(message, "content")) and
           String.trim(Map.get(message, "content")) != ""
       end) do
      {:ok, messages, schema}
    else
      {:error, :invalid_request}
    end
  end

  defp validate_body(_), do: {:error, :invalid_request}

  defp respond_result(conn, {:ok, result}) do
    send_json(conn, 200, %{
      output: result.output,
      model: result.model,
      reasoning_effort: result.reasoning_effort,
      usage: result.usage
    })
  end

  defp respond_result(conn, {:error, error}) do
    code =
      if error.code == :model_unavailable, do: 503, else: if(error.retryable, do: 502, else: 422)

    send_json(conn, code, %{
      error: %{
        code: Atom.to_string(error.code),
        message: error.message,
        retryable: error.retryable,
        details: error.details || %{}
      }
    })
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
