defmodule RutviExercise.HTTP.RouterTest do
  use ExUnit.Case, async: false

  alias RutviExercise.HTTP.Router

  defmodule RuntimeStub do
    def start(target, payload, caller, opts) do
      Process.put(:http_call, {:start, target, payload, caller, opts})

      {:ok,
       %{
         reference_id: "r1",
         task_id: "t1",
         run_id: "run1",
         service_id: "course.create",
         status: :queued
       }}
    end

    def inspect(ref, caller) do
      Process.put(:http_call, {:inspect, ref, caller})

      if ref == "missing" do
        {:error, :not_found}
      else
        {:ok, %{reference_id: ref, status: :completed, result: %{title: "Demo"}, error: nil}}
      end
    end

    def history(ref, caller, after_seq) do
      Process.put(:http_call, {:history, ref, caller, after_seq})
      {:ok, [%{sequence: 1, type: :queued}]}
    end

    def wait(ref, caller, timeout) do
      Process.put(:http_call, {:wait, ref, caller, timeout})
      {:ok, %{reference_id: ref, status: :queued}}
    end

    def resume(ref, checkpoint_id, response_id, payload, caller) do
      Process.put(:http_call, {:resume, ref, checkpoint_id, response_id, payload, caller})
      {:ok, %{reference_id: ref, status: :queued}}
    end

    def cancel(ref, caller) do
      Process.put(:http_call, {:cancel, ref, caller})
      {:ok, %{reference_id: ref, status: :cancelled}}
    end

    def resolve(query, caller) do
      Process.put(:http_call, {:resolve, query, caller})
      {:ok, %{reference_id: "r1", status: :completed}}
    end
  end

  setup do
    previous = Application.get_env(:rutvi_exercise, :http_identities)
    previous_runtime = Application.get_env(:rutvi_exercise, :http_runtime)
    previous_enabled = Application.get_env(:rutvi_exercise, :http_enabled)

    Application.put_env(:rutvi_exercise, :http_identities, %{
      "test-token-for-a-user1" => %{namespace_id: "A", user_id: "u1", session_id: "s1"},
      "test-token-for-a-user2" => %{namespace_id: "A", user_id: "u2", session_id: "s1"},
      "test-token-for-b-user1" => %{namespace_id: "B", user_id: "u1", session_id: "s1"}
    })

    Application.put_env(:rutvi_exercise, :http_runtime, RuntimeStub)
    Application.put_env(:rutvi_exercise, :http_enabled, false)
    Process.delete(:http_call)

    on_exit(fn ->
      restore(:http_identities, previous)
      restore(:http_runtime, previous_runtime)
      restore(:http_enabled, previous_enabled)
    end)
  end

  test "liveness is available without credentials and protected routes reject anonymous callers" do
    assert response(conn(:get, "/live")).resp_body == ~s({"status":"live"})

    result = response(conn(:get, "/v1/tasks/r1"))
    assert result.status == 401
    assert Jason.decode!(result.resp_body)["error"] == "unauthorized"
  end

  test "course creation takes caller scope from bearer identity, not JSON" do
    result =
      conn(:post, "/v1/courses", %{
        "payload" => %{"topic" => "events"},
        "namespace_id" => "forged",
        "user_id" => "admin",
        "session_id" => "other"
      })
      |> bearer("test-token-for-a-user1")
      |> response()

    assert result.status == 202
    assert Jason.decode!(result.resp_body)["reference_id"] == "r1"

    assert {:start, "course.create", %{"topic" => "events"}, caller, []} = Process.get(:http_call)
    assert caller.namespace_id == "A"
    assert caller.user_id == "u1"
    assert caller.session_id == "s1"
    assert is_binary(caller.request_id)
    refute caller.namespace_id == "forged"
  end

  test "state and history use the authenticated caller and preserve sequence cursors" do
    state = conn(:get, "/v1/tasks/r1") |> bearer("test-token-for-b-user1") |> response()
    assert state.status == 200
    assert {:inspect, "r1", %{namespace_id: "B", user_id: "u1"}} = Process.get(:http_call)

    events =
      conn(:get, "/v1/tasks/r1/history?after_seq=7")
      |> bearer("test-token-for-a-user2")
      |> response()

    assert events.status == 200
    assert {:history, "r1", %{namespace_id: "A", user_id: "u2"}, 7} = Process.get(:http_call)
  end

  test "wait duration is bounded and invalid values are rejected before runtime calls" do
    result =
      conn(:post, "/v1/tasks/r1/wait", %{"timeout_ms" => 30_001})
      |> bearer("test-token-for-a-user1")
      |> response()

    assert result.status == 422
    assert Jason.decode!(result.resp_body)["error"] == "validation_error"
    assert Process.get(:http_call) == nil
  end

  test "runtime errors map to stable HTTP statuses and codes" do
    result =
      conn(:get, "/v1/tasks/missing")
      |> bearer("test-token-for-a-user1")
      |> response()

    assert result.status == 404
    assert Jason.decode!(result.resp_body)["error"] == "not_found"
  end

  test "real HTTP course flow uses durable Runtime and denies another owner" do
    Application.delete_env(:rutvi_exercise, :http_runtime)

    started =
      conn(:post, "/v1/courses", %{
        "payload" => %{
          "topic" => "Základy událostmi řízených systémů",
          "audience" => "Juniorní backendoví vývojáři"
        },
        "namespace_id" => "B",
        "user_id" => "forged"
      })
      |> bearer("test-token-for-a-user1")
      |> response()

    assert started.status == 202
    reference_id = Jason.decode!(started.resp_body)["reference_id"]

    completed =
      conn(:post, "/v1/tasks/#{reference_id}/wait", %{"timeout_ms" => 30_000})
      |> bearer("test-token-for-a-user1")
      |> response()

    assert completed.status == 200
    assert Jason.decode!(completed.resp_body)["status"] == "completed"

    result =
      conn(:get, "/v1/tasks/#{reference_id}/result")
      |> bearer("test-token-for-a-user1")
      |> response()

    assert result.status == 200
    assert Jason.decode!(result.resp_body)["result"] != nil

    history =
      conn(:get, "/v1/tasks/#{reference_id}/history?after_seq=0")
      |> bearer("test-token-for-a-user1")
      |> response()

    assert history.status == 200
    assert Jason.decode!(history.resp_body)["events"] != []

    denied =
      conn(:get, "/v1/tasks/#{reference_id}")
      |> bearer("test-token-for-a-user2")
      |> response()

    assert denied.status == 403
    assert Jason.decode!(denied.resp_body)["error"] == "forbidden"
  end

  defp conn(method, path, body \\ nil) do
    value = if is_nil(body), do: "", else: Jason.encode!(body)

    Plug.Test.conn(method, path, value)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  defp response(conn), do: Router.call(conn, Router.init([]))

  defp restore(key, nil), do: Application.delete_env(:rutvi_exercise, key)
  defp restore(key, value), do: Application.put_env(:rutvi_exercise, key, value)
end
