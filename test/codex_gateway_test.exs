defmodule RutviExercise.CodexGatewayTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  @token String.duplicate("s", 64)
  @opts RutviExercise.CodexGateway.Router.init([])

  setup do
    Application.put_env(:rutvi_exercise, :codex_gateway_token, @token)
    {:ok, pid} = RutviExercise.CodexGateway.Limiter.start_link()

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.delete_env(:rutvi_exercise, :codex_gateway_token)
    end)

    :ok
  end

  test "requires bearer auth before model dispatch" do
    conn =
      conn(:post, "/v1/generate", Jason.encode!(%{"messages" => [], "output_schema" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> RutviExercise.CodexGateway.Router.call(@opts)

    assert conn.status == 401
  end

  test "rejects extra control fields even with valid bearer auth" do
    conn =
      conn(
        :post,
        "/v1/generate",
        Jason.encode!(%{
          "messages" => [%{"role" => "user", "content" => "x"}],
          "output_schema" => %{"type" => "object"},
          "command" => "forbidden"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> @token)
      |> RutviExercise.CodexGateway.Router.call(@opts)

    assert conn.status == 400
    refute conn.resp_body =~ "forbidden"
  end

  test "limiter releases a slot when an active HTTP owner dies" do
    name = String.to_atom("gateway_limiter_#{System.unique_integer([:positive])}")
    {:ok, pid} = RutviExercise.CodexGateway.Limiter.start_link(name: name)
    parent = self()

    owner =
      spawn(fn ->
        :ok = RutviExercise.CodexGateway.Limiter.acquire(name)
        send(parent, {:acquired, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:acquired, ^owner}, 1_000
    Process.exit(owner, :kill)
    assert :ok = RutviExercise.CodexGateway.Limiter.acquire(name)

    GenServer.stop(pid)
  end

  test "a dead queued owner is removed and cannot consume a later slot" do
    name = String.to_atom("gateway_limiter_#{System.unique_integer([:positive])}")
    {:ok, pid} = RutviExercise.CodexGateway.Limiter.start_link(name: name)
    parent = self()

    owners =
      for _ <- 1..2 do
        spawn(fn ->
          :ok = RutviExercise.CodexGateway.Limiter.acquire(name)
          send(parent, {:acquired, self()})
          Process.sleep(:infinity)
        end)
      end

    assert_receive {:acquired, first}, 1_000
    assert_receive {:acquired, second}, 1_000
    assert MapSet.new([first, second]) == MapSet.new(owners)
    queued = spawn(fn -> RutviExercise.CodexGateway.Limiter.acquire(name) end)
    wait_for_queue(name, 1)
    Process.exit(queued, :kill)
    Process.exit(hd(owners), :kill)
    Process.sleep(30)

    # The killed queued caller is discarded; this caller can take its slot.
    assert :ok = RutviExercise.CodexGateway.Limiter.acquire(name)
    Enum.each(tl(owners), &Process.exit(&1, :kill))
    GenServer.stop(pid)
  end

  defp wait_for_queue(name, expected, retries \\ 100)

  defp wait_for_queue(name, expected, retries) when retries > 0 do
    if :queue.len(:sys.get_state(name).queue) == expected do
      :ok
    else
      Process.sleep(10)
      wait_for_queue(name, expected, retries - 1)
    end
  end
end
