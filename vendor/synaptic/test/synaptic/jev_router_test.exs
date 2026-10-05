defmodule Synaptic.JevRouterTest do
  use ExUnit.Case, async: false
  alias Synaptic.{Jev, JevRouter}

  defmodule Workflow do
    use Synaptic.Workflow

    jev_router :triage,
               [{"Requests billing help", :billing}, {"Anything else", :other}],
               min_confidence: 0.8,
               fallback: :review,
               result_key: :triage_judgment do
      %{message: context.message}
    end

    step :billing do
      {:route, :done, %{handled: :billing}}
    end

    step :other do
      {:route, :done, %{handled: :other}}
    end

    step :review, suspend: true do
      case context[:human_input] do
        nil -> suspend_for_human("Please review this request.")
        _ -> {:ok, %{reviewed: true}}
      end
    end

    step :done do
      {:ok, %{finished: true}}
    end

    commit()
  end

  setup do
    original = Application.get_env(:synaptic, Jev)
    bypass = Bypass.open()

    opts = [
      endpoint: "http://localhost:#{bypass.port}/v1/systemone",
      api_key: "test-key",
      max_retries: 0
    ]

    Application.put_env(:synaptic, Jev, opts)

    on_exit(fn ->
      if original,
        do: Application.put_env(:synaptic, Jev, original),
        else: Application.delete_env(:synaptic, Jev)
    end)

    {:ok, bypass: bypass, opts: opts}
  end

  test "workflow router uses native Choice, selected state and preserves evidence", %{
    bypass: bypass
  } do
    parent = self()

    Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:payload, Jason.decode!(body)})
      respond(conn, 0.9)
    end)

    assert {:ok, run_id} =
             Synaptic.start(Workflow, %{
               message: "Please explain this charge",
               unrelated: "do not export"
             })

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context.handled == :billing
    assert snapshot.context.triage_judgment.answers["route"].choice == "branch_1"
    assert snapshot.context.triage_judgment.metadata.routing.used_fallback == false
    assert_receive {:payload, payload}
    assert payload["state"] == %{"message" => "Please explain this charge"}
    refute Map.has_key?(payload, "messages")

    assert payload["questions"]["route"]["criteria"] == %{
             "branch_1" => "Requests billing help",
             "branch_2" => "Anything else"
           }
  end

  test "low confidence routes to human review and retains result across resume", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", &respond(&1, 0.2))
    {:ok, run_id} = Synaptic.start(Workflow, %{message: "Something happened"})
    snapshot = wait_for(run_id, :waiting_for_human)
    assert snapshot.context.triage_judgment.metadata.routing.used_fallback
    assert snapshot.context.triage_judgment.metadata.routing.target == :review
    assert :ok = Synaptic.resume(run_id, %{approved: true})
    resumed = wait_for(run_id, :completed)
    assert resumed.context.triage_judgment.answers["route"].confidence == 0.2
  end

  test "uncertainty without fallback is explicit and does not trigger client retries", %{
    bypass: bypass,
    opts: opts
  } do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", &respond(&1, 0.1))

    assert {:error, {:jev_low_confidence, result}} =
             JevRouter.evaluate(%{}, branches(), "state", Keyword.put(opts, :max_retries, 2))

    assert result.answers["route"].confidence == 0.1
  end

  test "transport failures do not masquerade as low confidence", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", &Plug.Conn.resp(&1, 401, "unauthorized"))

    assert {:error, {:jev_http_error, 401}} =
             JevRouter.evaluate(%{}, branches(), "state", Keyword.put(opts, :fallback, :review))
  end

  test "confidence equal to the threshold takes the selected route", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", &respond(&1, 0.8))

    assert {:ok, :billing, %{jev_result: _}} =
             JevRouter.evaluate(
               %{},
               branches(),
               "state",
               Keyword.merge(opts, min_confidence: 0.8, fallback: :review)
             )
  end

  test "compile-time validation covers branches, fallback targets, confidence and unsupported chat options" do
    for bad <- [
          [branches: [{"Billing", :missing}, {"Other", :other}]],
          [fallback: :missing],
          [min_confidence: 1.1],
          [temperature: 0]
        ] do
      name = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")
      branches = Keyword.get(bad, :branches, branches())
      opts = Keyword.delete(bad, :branches)

      assert_raise ArgumentError, ~r/jev_router/, fn ->
        Code.compile_quoted(
          quote do
            defmodule unquote(name) do
              use Synaptic.Workflow

              jev_router :triage, unquote(Macro.escape(branches)), unquote(Macro.escape(opts)) do
                %{}
              end

              step :billing do
                {:ok, %{}}
              end

              step :other do
                {:ok, %{}}
              end

              commit()
            end
          end
        )
      end
    end
  end

  defp branches, do: [{"Billing", :billing}, {"Other", :other}]

  defp respond(conn, confidence) do
    body = %{
      model: "jev-1.13.0",
      usage: %{input_tokens: 25, output_tokens: 5},
      answers: %{
        route: %{
          type: "choice",
          choice: "branch_1",
          confidence: confidence,
          probabilities: %{branch_1: 0.9, branch_2: 0.1}
        }
      }
    }

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp wait_for(run_id, status, attempts \\ 50)
  defp wait_for(_run_id, _status, 0), do: flunk("workflow did not reach expected status")

  defp wait_for(run_id, status, attempts) do
    snapshot = Synaptic.inspect(run_id)

    if snapshot.status == status do
      snapshot
    else
      Process.sleep(20)
      wait_for(run_id, status, attempts - 1)
    end
  end
end
