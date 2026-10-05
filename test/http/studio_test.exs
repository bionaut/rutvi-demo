defmodule RutviExercise.HTTP.StudioTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias RutviExercise.HTTP.Router

  setup do
    previous = Application.get_env(:rutvi_exercise, :studio_demo)
    Application.put_env(:rutvi_exercise, :studio_demo, true)
    RutviExercise.Course.register()
    on_exit(fn -> Application.put_env(:rutvi_exercise, :studio_demo, previous) end)
    :ok
  end

  defp send_request(method, path, session \\ nil, payload \\ nil, headers \\ []) do
    conn = conn(method, path, if(payload, do: Jason.encode!(payload), else: nil))
    conn = if session, do: recycle_cookies(conn, session), else: conn

    conn =
      if payload,
        do: Plug.Conn.put_req_header(conn, "content-type", "application/json"),
        else: conn

    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc ->
        Plug.Conn.put_req_header(acc, key, value)
      end)

    Router.call(conn, Router.init([]))
  end

  defp session do
    response = send_request(:get, "/studio-api/session")
    {response, Jason.decode!(response.resp_body)["csrf"]}
  end

  test "static working surface contains no credentials; demo defaults closed and v1 stays authenticated" do
    Application.put_env(:rutvi_exercise, :studio_demo, false)
    page = send_request(:get, "/")
    assert page.status == 200
    assert page.resp_body =~ "Rutvi Course Studio"
    refute page.resp_body =~ "dev-token"
    assert send_request(:get, "/studio/app.js").status == 200
    assert send_request(:get, "/studio/app.css").status == 200
    assert send_request(:get, "/studio-api/session").status == 404
    assert send_request(:post, "/v1/courses", nil, %{payload: %{}}).status == 401
    assert Plug.Conn.get_resp_header(page, "content-security-policy") != []
  end

  test "signed HttpOnly session requires CSRF and same origin for mutations" do
    {session, csrf} = session()
    [cookie] = Plug.Conn.get_resp_header(session, "set-cookie")
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Strict"
    payload = %{payload: %{topic: "Event-driven systems"}}
    assert send_request(:post, "/studio-api/courses", session, payload).status == 403

    assert send_request(:post, "/studio-api/courses", session, payload, [
             {"x-rutvi-csrf", csrf},
             {"origin", "https://attacker.example"}
           ]).status == 403

    assert send_request(:get, "/studio-api/session", session).resp_body
           |> Jason.decode!()
           |> Map.get("csrf") == csrf
  end

  test "browser input runs actual course, exposes checkpoint, resumes and returns artifact with isolated scope" do
    {session, csrf} = session()

    started =
      send_request(
        :post,
        "/studio-api/courses",
        session,
        %{payload: %{topic: "Event-driven systems"}},
        [{"x-rutvi-csrf", csrf}]
      )

    assert started.status == 202
    root = Jason.decode!(started.resp_body)
    ref = root["task_id"]
    assert root["namespace_id"] == "A"
    assert String.starts_with?(root["user_id"], "studio-demo:")
    caller = Map.new([:namespace_id, :user_id, :session_id], &{&1, root[Atom.to_string(&1)]})
    {:ok, paused} = RutviExercise.Runtime.wait(ref, caller, 30_000)
    assert Enum.any?(paused.checkpoints, &is_nil(&1.response))
    view = send_request(:get, "/studio-api/tasks/#{ref}", session)
    checkpoint = Enum.find(Jason.decode!(view.resp_body)["checkpoints"], &is_nil(&1["response"]))
    {other_session, other_csrf} = session()
    assert send_request(:get, "/studio-api/tasks/#{ref}", other_session).status == 403
    assert send_request(:get, "/studio-api/tasks/#{ref}/export", other_session).status == 403
    assert send_request(:get, "/studio-api/tasks/#{ref}/export", session).status == 409

    assert send_request(:delete, "/studio-api/tasks/#{ref}", other_session, %{}, [
             {"x-rutvi-csrf", other_csrf}
           ]).status == 403

    resumed =
      send_request(
        :post,
        "/studio-api/tasks/#{ref}/resume",
        session,
        %{
          checkpoint_id: checkpoint["checkpoint_id"],
          response_id: "browser-answer",
          payload: %{audience: "Junior developers"}
        },
        [{"x-rutvi-csrf", csrf}]
      )

    assert resumed.status == 200
    {:ok, complete} = RutviExercise.Runtime.wait(ref, caller, 30_000)
    assert complete.status == :completed

    result =
      send_request(:get, "/studio-api/tasks/#{ref}", session)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert length(result["result"]["lessons"]) == 2
    assert length(result["result"]["questions"]) == 3

    exported = send_request(:get, "/studio-api/tasks/#{ref}/export", session)
    assert exported.status == 200

    assert Plug.Conn.get_resp_header(exported, "content-disposition") ==
             [~s(attachment; filename="rutvi-course.json")]

    assert Jason.decode!(exported.resp_body) == result["result"]
    assert send_request(:get, "/studio-api/tasks/#{ref}/export", other_session).status == 403

    history =
      send_request(:get, "/studio-api/tasks/#{ref}/history", session)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert Enum.any?(
             history,
             &(&1["service_id"] == "course.review" and &1["type"] == "completed")
           )

    assert send_request(
             :get,
             "/studio-api/tasks/#{ref}/history?after_seq=#{List.last(history)["sequence"]}",
             session
           ).resp_body == "[]"
  end
end
