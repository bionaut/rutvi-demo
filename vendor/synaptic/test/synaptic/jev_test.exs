defmodule Synaptic.JevTest do
  use ExUnit.Case, async: true
  alias Synaptic.Jev
  alias Synaptic.Jev.{ChoiceAnswer, NoulAnswer, Result, ScoreAnswer}

  setup do
    bypass = Bypass.open()

    opts = [
      endpoint: "http://localhost:#{bypass.port}/v1/systemone",
      api_key: "test-key",
      max_retries: 0
    ]

    {:ok, bypass: bypass, opts: opts}
  end

  test "batches all primitives and retains structured inputs, answers, model and native usage", %{
    bypass: bypass,
    opts: opts
  } do
    parent = self()
    criteria = [%{"summary" => "No impact"}, %{"summary" => "Work blocked"}]

    questions = %{
      "category" =>
        Jev.choice(%{question: "Which category fits `ticket`?"}, %{
          "bug" => %{what: "Broken software"},
          "other" => nil
        }),
      "severity" => Jev.score("How severe is `ticket`?", criteria),
      "refund" =>
        Jev.noul("Does `ticket` ask for a refund?", %{
          "true" => ["Refund requested"],
          "false" => "No refund request"
        })
    }

    Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        parent,
        {:request, Jason.decode!(body), Plug.Conn.get_req_header(conn, "authorization")}
      )

      respond(conn, %{
        model: "jev-1.13.0",
        usage: %{input_tokens: 85, output_tokens: 12},
        answers: %{
          category: %{
            type: "choice",
            choice: "bug",
            confidence: 0.7,
            probabilities: %{bug: 0.9, other: 0.1}
          },
          severity: %{
            type: "score",
            score: 0.8,
            confidence: 0.5,
            probabilities: %{"0" => 0.2, "1" => 0.8},
            legend: %{"0" => Enum.at(criteria, 0), "1" => Enum.at(criteria, 1)}
          },
          refund: %{type: "noul", noul: 0.51}
        }
      })
    end)

    assert {:ok, %Result{} = result} =
             Jev.evaluate(%{ticket: "Broken. Please refund."}, questions, opts)

    assert_receive {:request, payload, ["Bearer test-key"]}
    assert payload["state"] == %{"ticket" => "Broken. Please refund."}

    assert payload["questions"]["category"]["instructions"] == %{
             "question" => "Which category fits `ticket`?"
           }

    assert payload["questions"]["category"]["criteria"]["bug"] == %{"what" => "Broken software"}
    assert map_size(payload["questions"]) == 3
    assert %ChoiceAnswer{choice: "bug", confidence: 0.7} = result.answers["category"]
    assert %ScoreAnswer{score: 0.8} = result.answers["severity"]

    assert result.answers["severity"].legend == %{
             "0" => Enum.at(criteria, 0),
             "1" => Enum.at(criteria, 1)
           }

    assert %NoulAnswer{noul: 0.51} = result.answers["refund"]
    refute Map.has_key?(result.answers["refund"], :confidence)
    assert result.usage == %{input_tokens: 85, output_tokens: 12}
    assert result.request_id == "jev-test-request"
    assert {:ok, _} = Jason.encode(result)
  end

  test "accepts raw question maps and one-sided Noul criteria", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body)["questions"]["check"]["criteria"] == %{
               "true" => "Explicit refund request"
             }

      respond(conn, response())
    end)

    assert {:ok, _} =
             Jev.evaluate(
               "state",
               %{
                 "check" => %{
                   "type" => "noul",
                   "instructions" => "Does this ask for a refund?",
                   "criteria" => %{"true" => "Explicit refund request"}
                 }
               },
               opts
             )
  end

  test "rejects invalid questions and chat options before HTTP", %{opts: opts} do
    assert {:error, :invalid_questions} = Jev.evaluate("state", %{}, opts)

    assert {:error, {:invalid_question, "bad"}} =
             Jev.evaluate("state", %{"bad" => Jev.score("rate", ["only one"])}, opts)

    assert {:error, {:unsupported_jev_options, [:temperature]}} =
             Jev.evaluate("state", questions(), Keyword.put(opts, :temperature, 0))

    assert {:error, :invalid_jev_state} = Jev.evaluate(self(), questions(), opts)

    assert {:error, :missing_typesafe_api_key} =
             Jev.evaluate("state", questions(), Keyword.put(opts, :api_key, ""))
  end

  test "malformed answers are rejected, never repaired or retried", %{bypass: bypass, opts: opts} do
    for answer <- [nil, %{type: "noul", noul: 1.5}, %{type: "choice", choice: "yes"}] do
      Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
        respond(conn, %{model: "jev-1.13.0", answers: %{check: answer}, usage: %{}})
      end)

      assert {:error, :invalid_jev_response} =
               Jev.evaluate("state", questions(), Keyword.put(opts, :max_retries, 2))
    end
  end

  test "validates answer IDs and full distributions" do
    choice = %{"q" => %{"type" => "choice", "criteria" => %{"a" => "A", "b" => "B"}}}
    answer = %{type: "choice", choice: "a", confidence: 0.7, probabilities: %{a: 0.9, b: 0.1}}

    for answers <- [
          %{},
          %{q: answer, extra: answer},
          %{q: %{answer | choice: "unknown"}},
          %{q: %{answer | probabilities: %{a: 0.9}}},
          %{q: %{answer | probabilities: %{a: 0.9, b: 0.9}}},
          %{q: %{answer | confidence: -0.1}}
        ] do
      body = Jason.encode!(%{model: "jev-1.13.0", usage: %{}, answers: answers})
      assert {:error, :invalid_jev_response} = Result.decode(body, [], choice)
    end
  end

  test "retries overload responses with Retry-After, without changing the request", %{
    bypass: bypass,
    opts: opts
  } do
    {:ok, counter} = Agent.start_link(fn -> [] end)

    Bypass.expect(bypass, "POST", "/v1/systemone", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      attempt = Agent.get_and_update(counter, fn bodies -> {length(bodies), [body | bodies]} end)

      if attempt == 0 do
        # Plug has no built-in reason phrase for TypeSafe's nonstandard 529.
        {adapter, req} = conn.adapter
        req = :cowboy_req.reply("529 Overloaded", %{"retry-after" => "0"}, "overloaded", req)
        send(self(), {:plug_conn, :sent})
        %{conn | state: :sent, status: 529, adapter: {adapter, req}}
      else
        respond(conn, response())
      end
    end)

    assert {:ok, _} = Jev.evaluate("state", questions(), Keyword.put(opts, :max_retries, 1))
    assert [same, same] = Agent.get(counter, & &1)
  end

  test "does not retry auth errors or expose response bodies", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
      Plug.Conn.resp(conn, 401, "secret echoed by upstream")
    end)

    assert {:error, {:jev_http_error, 401}} =
             Jev.evaluate("state", questions(), Keyword.put(opts, :max_retries, 2))
  end

  test "does not sleep past the total budget on Retry-After", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "3600")
      |> Plug.Conn.resp(429, "rate limited")
    end)

    assert {:error, {:jev_http_error, 429}} =
             Jev.evaluate(
               "state",
               questions(),
               Keyword.merge(opts, max_retries: 2, timeout: 1_000)
             )
  end

  test "privacy transforms nested state and structured question descriptions before export", %{
    bypass: bypass,
    opts: opts
  } do
    parent = self()

    Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, body})
      respond(conn, response())
    end)

    questions = %{"check" => Jev.noul(%{question: "Does `ticket` mention jane@example.com?"})}

    assert {:ok, _} =
             Jev.evaluate(
               %{ticket: %{email: "jane@example.com"}},
               questions,
               Keyword.put(opts, :privacy, enabled: true)
             )

    assert_receive {:body, body}
    refute body =~ "jane@example.com"
    assert is_map(Jason.decode!(body)["state"]["ticket"])
    assert is_map(Jason.decode!(body)["questions"]["check"]["instructions"])
  end

  test "egress, gateway and tenant policies block before network", %{opts: opts} do
    assert {:error, {:egress_blocked, _}} =
             Jev.evaluate("state", questions(), Keyword.put(opts, :egress, enabled: true))

    assert {:error, {:connector_gateway_blocked, _}} =
             Jev.evaluate(
               "state",
               questions(),
               Keyword.put(opts, :connector_gateway, enabled: true, tls: [require_https: true])
             )

    assert {:error, {:security_policy_failed, %{reason: "tenant_required"}}} =
             Jev.evaluate(
               "state",
               questions(),
               Keyword.put(opts, :security_policy,
                 enabled: true,
                 tenant: [required_surfaces: [:prompt]]
               )
             )
  end

  test "judgment profiles report only implemented boundaries" do
    report = Synaptic.explain_security(:judgment, security_profile: :high_assurance)
    assert report.boundaries.privacy.enabled
    assert report.boundaries.egress.jev.allow_hosts == ["api.typesafe.ai"]
    assert report.diagnostics.errors == []
    refute Map.has_key?(report.boundaries, :factuality)
    refute Map.has_key?(report.boundaries, :tool_policy)
  end

  test "privacy cannot silently remove a Choice option", %{opts: opts} do
    questions = %{
      "route" =>
        Jev.choice("Classify `message`", %{
          "remove_me" => "Sensitive category",
          "keep" => "Category B",
          "other" => "Anything else"
        })
    }

    opts =
      Keyword.put(opts, :privacy, enabled: true, prompt: [field_actions: %{"remove_me" => :drop}])

    assert {:error, :jev_answer_space_changed_by_policy} = Jev.evaluate("state", questions, opts)
  end

  test "sanitization preserves structured instructions and cleans nested state", %{
    bypass: bypass,
    opts: opts
  } do
    parent = self()

    Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:sanitized, Jason.decode!(body)})
      respond(conn, response())
    end)

    assert {:ok, result} =
             Jev.evaluate(
               %{message: "<b>Hello</b>"},
               questions(),
               Keyword.merge(opts, security_profile: :production, security_explain: true)
             )

    assert_receive {:sanitized, %{"state" => %{"message" => "Hello"}}}
    assert result.metadata.security.profile.name == :production
    assert {:ok, _} = Jason.encode(result)
  end

  test "HTTP-date retry headers and retry budget are honored", %{bypass: bypass, opts: opts} do
    parent = self()

    Bypass.expect(bypass, "POST", "/v1/systemone", fn conn ->
      send(parent, :attempt)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "Wed, 01 Jan 2020 00:00:00 GMT")
      |> Plug.Conn.resp(429, "rate limited")
    end)

    assert {:error, {:jev_http_error, 429}} =
             Jev.evaluate("state", questions(), Keyword.put(opts, :max_retries, 1))

    assert_receive :attempt
    assert_receive :attempt
    refute_receive :attempt
  end

  test "total deadline includes slow outbound preflight", %{opts: opts} do
    parent = self()

    resolver = fn _host ->
      send(parent, :resolving)
      Process.sleep(200)
      {:ok, [{93, 184, 216, 34}]}
    end

    opts =
      Keyword.merge(opts,
        timeout: 25,
        endpoint: "https://api.typesafe.ai/v1/systemone",
        egress: [enabled: true, jev: [dns_resolver: resolver]]
      )

    assert {:error, :jev_timeout} = Jev.evaluate("state", questions(), opts)
    assert_receive :resolving
  end

  test "telemetry reports native usage and no prompt or answer content", %{
    bypass: bypass,
    opts: opts
  } do
    id = "jev-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:synaptic, :jev, :stop],
      fn event, measurements, metadata, pid -> send(pid, {event, measurements, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
    Bypass.expect_once(bypass, "POST", "/v1/systemone", &respond(&1, response()))

    assert {:ok, result} =
             Jev.evaluate(
               "private state",
               questions(),
               Keyword.merge(opts,
                 run_id: id,
                 security_explain: true,
                 audit: [enabled: true, return_metadata: true]
               )
             )

    assert result.usage == %{input_tokens: nil, output_tokens: nil}
    assert result.metadata.security.surface == :judgment
    assert result.metadata.audit

    assert_receive {[:synaptic, :jev, :stop], %{duration: _},
                    %{run_id: ^id, status: :ok} = metadata}

    refute inspect(metadata) =~ "private state"
    refute Map.has_key?(metadata, :answers)
    assert metadata.question_count == 1
    assert metadata.usage == result.usage
  end

  defp questions, do: %{"check" => Jev.noul("Does `state` contain a request?")}

  defp response,
    do: %{model: "jev-1.13.0", usage: %{}, answers: %{check: %{type: "noul", noul: 0.51}}}

  defp respond(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.put_resp_header("x-typesafe-request-id", "jev-test-request")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
