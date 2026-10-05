defmodule RutviExercise.HTTP.Studio do
  @moduledoc "Explicitly enabled local demonstration UI. API bearer authentication remains separate."
  import Plug.Conn
  @behaviour Plug

  def init(opts), do: opts

  def call(%{request_path: path} = conn, _)
      when path in ["/", "/studio/app.js", "/studio/app.css"] do
    if conn.method in ["GET", "HEAD"] do
      {file, type} =
        case path do
          "/" -> {"index.html", "text/html"}
          "/studio/app.js" -> {"app.js", "text/javascript"}
          _ -> {"app.css", "text/css"}
        end

      conn
      |> put_resp_header(
        "content-security-policy",
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
      )
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type(type)
      |> send_file(200, Application.app_dir(:rutvi_exercise, "priv/studio/#{file}"))
      |> halt()
    else
      conn
    end
  end

  def call(%{request_path: "/studio-api/" <> _} = conn, _) do
    if Application.get_env(:rutvi_exercise, :studio_demo, false) do
      conn = %{conn | secret_key_base: Application.fetch_env!(:rutvi_exercise, :studio_secret)}

      opts =
        Plug.Session.init(
          store: :cookie,
          key: "rutvi_studio",
          signing_salt: "studio-v1",
          http_only: true,
          same_site: "Strict",
          secure: conn.scheme == :https
        )

      conn =
        conn
        |> Plug.Session.call(opts)
        |> fetch_session()
        |> put_resp_header("cache-control", "no-store")

      conn =
        if get_session(conn, :identity),
          do: conn,
          else: put_session(conn, :identity, RutviExercise.Store.id())

      conn =
        if get_session(conn, :csrf),
          do: conn,
          else: put_session(conn, :csrf, RutviExercise.Store.id())

      dispatch(conn) |> halt()
    else
      reply(conn, 404, %{
        error: "demo_disabled",
        message: "The browser demonstration is disabled on this server."
      })
      |> halt()
    end
  end

  def call(conn, _), do: conn

  defp dispatch(%{method: "GET", request_path: "/studio-api/session"} = conn) do
    provider =
      if Application.get_env(:rutvi_exercise, :model_adapter) ==
           RutviExercise.Models.Deterministic,
         do: "demonstration",
         else: "codex"

    reply(conn, 200, %{
      csrf: get_session(conn, :csrf),
      provider: provider,
      model: Application.get_env(:rutvi_exercise, :model),
      topic: "Základy událostmi řízených systémů",
      sources: RutviExercise.Course.Sources.all()
    })
  end

  defp dispatch(conn) do
    with :ok <- mutation_allowed(conn) do
      route(conn)
    else
      {:error, reason} ->
        reply(conn, 403, %{error: reason, message: "Refresh the page and try again."})
    end
  end

  defp route(%{method: "POST", request_path: "/studio-api/courses"} = conn) do
    with {:ok, conn, body} <- body(conn),
         payload when is_map(payload) <- body["payload"],
         topic when is_binary(topic) and byte_size(topic) in 1..300 <- payload["topic"] do
      payload = Map.take(payload, ["topic", "audience", "style", "ask_style"])

      result(
        conn,
        :start,
        [
          Application.get_env(:rutvi_exercise, :course_service_id, "course.create"),
          payload,
          caller(conn),
          []
        ],
        202
      )
    else
      _ -> reply(conn, 422, %{error: "invalid_input", message: "Enter a course topic."})
    end
  end

  defp route(conn) do
    case {conn.method, String.split(conn.request_path, "/", trim: true)} do
      {"GET", ["studio-api", "tasks", ref]} ->
        result(conn, :inspect, [ref, caller(conn)])

      {"GET", ["studio-api", "tasks", ref, "export"]} ->
        export(conn, ref)

      {"GET", ["studio-api", "tasks", ref, "history"]} ->
        conn = fetch_query_params(conn)

        after_seq =
          case Integer.parse(conn.query_params["after_seq"] || "0") do
            {n, ""} when n >= 0 -> n
            _ -> 0
          end

        result(conn, :history, [ref, caller(conn), after_seq])

      {"POST", ["studio-api", "tasks", ref, "resume"]} ->
        with {:ok, conn, body} <- body(conn),
             checkpoint when is_binary(checkpoint) <- body["checkpoint_id"],
             response when is_binary(response) <- body["response_id"],
             payload when is_map(payload) <- body["payload"] do
          result(conn, :resume, [ref, checkpoint, response, payload, caller(conn)])
        else
          _ ->
            reply(conn, 422, %{
              error: "invalid_answer",
              message: "Complete the follow-up question."
            })
        end

      {"DELETE", ["studio-api", "tasks", ref]} ->
        result(conn, :cancel, [ref, caller(conn)])

      _ ->
        reply(conn, 404, %{error: "not_found"})
    end
  end

  defp export(conn, ref) do
    runtime = conn.private[:rutvi_http_runtime] || RutviExercise.Runtime

    case runtime.inspect(ref, caller(conn)) do
      {:ok, %{status: :completed, result: artifact}} when is_map(artifact) ->
        conn
        |> put_resp_header("content-disposition", ~s(attachment; filename="rutvi-course.json"))
        |> reply(200, artifact)

      {:ok, _} ->
        reply(conn, 409, %{error: "not_complete", message: "The course is not complete yet."})

      {:error, :forbidden} ->
        reply(conn, 403, %{error: "forbidden"})

      {:error, :not_found} ->
        reply(conn, 404, %{error: "not_found"})

      _ ->
        reply(conn, 503, %{error: "unavailable"})
    end
  rescue
    _ -> reply(conn, 503, %{error: "unavailable"})
  catch
    :exit, _ -> reply(conn, 503, %{error: "unavailable"})
  end

  defp caller(conn),
    do: %{
      namespace_id: Application.get_env(:rutvi_exercise, :studio_namespace, "A"),
      user_id: "studio-demo:" <> get_session(conn, :identity),
      session_id: get_session(conn, :identity),
      request_id: RutviExercise.Store.id()
    }

  defp mutation_allowed(%{method: method}) when method in ["GET", "HEAD"], do: :ok

  defp mutation_allowed(conn) do
    csrf = get_session(conn, :csrf)
    supplied = get_req_header(conn, "x-rutvi-csrf")

    origin_ok =
      case get_req_header(conn, "origin") do
        [] ->
          true

        [origin] ->
          uri = URI.parse(origin)

          uri.scheme == Atom.to_string(conn.scheme) and uri.host == conn.host and
            uri.port == conn.port

        _ ->
          false
      end

    json? =
      Enum.any?(
        get_req_header(conn, "content-type"),
        &String.starts_with?(&1, "application/json")
      )

    if origin_ok and supplied == [csrf] and json?,
      do: :ok,
      else: {:error, "invalid_session"}
  end

  defp body(conn) do
    case read_body(conn, length: 16_384) do
      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, data} when is_map(data) -> {:ok, conn, data}
          _ -> {:error, :invalid_json}
        end

      _ ->
        {:error, :invalid_json}
    end
  end

  defp result(conn, operation, args, status \\ 200) do
    runtime = conn.private[:rutvi_http_runtime] || RutviExercise.Runtime

    case apply(runtime, operation, args) do
      {:ok, value} ->
        reply(conn, status, value)

      {:error, reason} ->
        code =
          case reason do
            :forbidden -> 403
            :not_found -> 404
            :conflict -> 409
            _ -> 422
          end

        reply(conn, code, %{
          error: reason,
          message: "The operation could not be completed. Try refreshing the task."
        })
    end
  rescue
    _ ->
      reply(conn, 503, %{
        error: "unavailable",
        message: "The service is unavailable. Try again shortly."
      })
  catch
    :exit, _ ->
      reply(conn, 503, %{
        error: "unavailable",
        message: "The service is restarting. Refresh shortly."
      })
  end

  defp reply(conn, status, value),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(safe(value)))

  defp safe(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), safe(v)} end)

  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)
  defp safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> safe()

  defp safe(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp safe(value), do: value
end
