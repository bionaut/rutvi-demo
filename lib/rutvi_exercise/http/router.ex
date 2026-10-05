defmodule RutviExercise.HTTP.Router do
  @moduledoc """
  JSON API for course creation and durable task control.
  """
  use Plug.Router

  @max_wait_ms 30_000

  plug(RutviExercise.HTTP.Studio)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    length: 1_048_576,
    read_length: 65_536,
    read_timeout: 5_000
  )

  plug(:match)
  plug(:dispatch)

  get "/live" do
    json(conn, 200, %{status: "live"})
  end

  get "/ready" do
    if ready?(conn) do
      json(conn, 200, %{status: "ready"})
    else
      json(conn, 503, %{error: "not_ready", message: "application store is not ready"})
    end
  end

  post "/v1/courses" do
    with_body(conn, fn conn, caller, body ->
      with {:ok, payload} <- required_map(body, "payload"),
           {:ok, result} <- invoke(conn, :start, [course_service_id(), payload, caller, []]) do
        json(conn, 202, result)
      else
        {:error, reason} -> error(conn, reason)
      end
    end)
  end

  post "/v1/tasks" do
    with_body(conn, fn conn, caller, body ->
      target =
        cond do
          is_binary(body["service_id"]) and body["service_id"] != "" ->
            body["service_id"]

          is_binary(body["capability"]) and body["capability"] != "" ->
            %{capability: body["capability"]}

          true ->
            nil
        end

      with {:ok, payload} <- required_map(body, "payload"),
           true <- not is_nil(target) or {:error, :validation_error},
           {:ok, result} <- invoke(conn, :start, [target, payload, caller, []]) do
        json(conn, 202, result)
      else
        {:error, reason} -> error(conn, reason)
        false -> error(conn, :validation_error)
      end
    end)
  end

  get "/v1/tasks/:ref/result" do
    with_caller(conn, fn conn, caller ->
      case invoke(conn, :inspect, [ref, caller]) do
        {:ok, snapshot} ->
          json(conn, 200, %{
            reference_id: ref,
            status: Map.get(snapshot, :status),
            result: Map.get(snapshot, :result),
            error: Map.get(snapshot, :error)
          })

        {:error, reason} ->
          error(conn, reason)
      end
    end)
  end

  get "/v1/tasks/:ref/history" do
    with_caller(conn, fn conn, caller ->
      with {:ok, after_seq} <- query_integer(conn, "after_seq", 0),
           {:ok, events} <- invoke(conn, :history, [ref, caller, after_seq]) do
        json(conn, 200, %{reference_id: ref, events: events})
      else
        {:error, reason} -> error(conn, reason)
      end
    end)
  end

  get "/v1/tasks/:ref" do
    with_caller(conn, fn conn, caller ->
      case invoke(conn, :inspect, [ref, caller]) do
        {:ok, snapshot} -> json(conn, 200, snapshot)
        {:error, reason} -> error(conn, reason)
      end
    end)
  end

  post "/v1/tasks/:ref/wait" do
    with_body(conn, fn conn, caller, body ->
      timeout = body["timeout_ms"] || 0

      if is_integer(timeout) and timeout >= 0 and timeout <= @max_wait_ms do
        case invoke(conn, :wait, [ref, caller, timeout]) do
          {:ok, snapshot} -> json(conn, 200, snapshot)
          {:error, reason} -> error(conn, reason)
        end
      else
        error(conn, :validation_error)
      end
    end)
  end

  post "/v1/tasks/:ref/resume" do
    with_body(conn, fn conn, caller, body ->
      checkpoint_id = body["checkpoint_id"]
      response_id = body["response_id"]

      if is_binary(checkpoint_id) and checkpoint_id != "" and is_binary(response_id) and
           response_id != "" and is_map(body["payload"]) do
        case invoke(conn, :resume, [ref, checkpoint_id, response_id, body["payload"], caller]) do
          {:ok, snapshot} -> json(conn, 200, snapshot)
          {:error, reason} -> error(conn, reason)
        end
      else
        error(conn, :validation_error)
      end
    end)
  end

  delete "/v1/tasks/:ref" do
    with_caller(conn, fn conn, caller ->
      case invoke(conn, :cancel, [ref, caller]) do
        {:ok, snapshot} -> json(conn, 200, snapshot)
        {:error, reason} -> error(conn, reason)
      end
    end)
  end

  post "/v1/resolve" do
    with_body(conn, fn conn, caller, body ->
      query = body["query"]

      if is_map(query) do
        case invoke(conn, :resolve, [atomize_known_query(query), caller]) do
          {:ok, snapshot} -> json(conn, 200, snapshot)
          {:error, reason} -> error(conn, reason)
        end
      else
        error(conn, :validation_error)
      end
    end)
  end

  match _ do
    json(conn, 404, %{error: "not_found", message: "route not found"})
  end

  defp with_body(conn, fun) do
    with_caller(conn, fn conn, caller ->
      if is_map(conn.body_params) and map_size(conn.body_params) > 0 do
        fun.(conn, caller, conn.body_params)
      else
        error(conn, :validation_error)
      end
    end)
  end

  defp with_caller(conn, fun) do
    case RutviExercise.HTTP.Auth.caller(conn) do
      {:ok, caller} ->
        request_id =
          case Plug.Conn.get_req_header(conn, "x-request-id") do
            [value] when byte_size(value) in 1..128 -> value
            _ -> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
          end

        fun.(conn, Map.put(caller, :request_id, request_id))

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp invoke(conn, function, args) do
    runtime =
      conn.private[:rutvi_http_runtime] ||
        Application.get_env(:rutvi_exercise, :http_runtime, RutviExercise.Runtime)

    try do
      apply(runtime, function, args)
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end

  defp ready?(conn) do
    check =
      conn.private[:rutvi_http_ready_check] ||
        Application.get_env(:rutvi_exercise, :http_ready_check)

    result =
      cond do
        is_function(check, 0) -> check.()
        function_exported?(RutviExercise.Runtime, :ready?, 0) -> RutviExercise.Runtime.ready?()
        true -> Process.whereis(RutviExercise.Store) != nil
      end

    result == true or result == :ok or result == {:ok, :ready}
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp course_service_id do
    Application.get_env(:rutvi_exercise, :course_service_id, "course.create")
  end

  defp required_map(body, key) do
    case body[key] do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, :validation_error}
    end
  end

  defp query_integer(conn, key, default) do
    case conn.query_params[key] do
      nil ->
        {:ok, default}

      value ->
        case Integer.parse(value) do
          {integer, ""} when integer >= 0 -> {:ok, integer}
          _ -> {:error, :validation_error}
        end
    end
  end

  defp atomize_known_query(query) do
    mapping = %{
      "alias" => :alias,
      "capability" => :capability,
      "purpose" => :purpose,
      "latest" => :latest,
      "active_only" => :active_only,
      "service_id" => :service_id,
      "reference_id" => :reference_id,
      "task_id" => :task_id,
      "run_id" => :run_id
    }

    Enum.reduce(query, %{}, fn {key, value}, acc ->
      case mapping[key] do
        nil -> acc
        atom -> Map.put(acc, atom, value)
      end
    end)
  end

  defp error(conn, reason) do
    {status, code} = error_status(reason)
    json(conn, status, %{error: Atom.to_string(code), message: Atom.to_string(code)})
  end

  defp error_status(:unauthorized), do: {401, :unauthorized}
  defp error_status(:authentication_not_configured), do: {503, :authentication_not_configured}
  defp error_status(:forbidden), do: {403, :forbidden}
  defp error_status(:not_found), do: {404, :not_found}
  defp error_status(:conflict), do: {409, :conflict}
  defp error_status(:ambiguous_target), do: {409, :ambiguous_target}
  defp error_status(:ambiguous_reference), do: {409, :ambiguous_reference}
  defp error_status(:validation_error), do: {422, :validation_error}
  defp error_status(:limit_exceeded), do: {429, :limit_exceeded}
  defp error_status(:unavailable), do: {503, :unavailable}
  defp error_status(_), do: {500, :internal_error}

  defp json(conn, status, body) do
    Plug.Conn.put_resp_content_type(conn, "application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(json_safe(body)))
  end

  defp json_safe(nil), do: nil
  defp json_safe(value) when value in [true, false], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(%_{} = value), do: value |> Map.from_struct() |> json_safe()
  defp json_safe(value) when is_pid(value), do: "[pid]"
  defp json_safe(value) when is_reference(value), do: "[reference]"
  defp json_safe(value) when is_function(value), do: "[function]"
  defp json_safe(value), do: value
end
