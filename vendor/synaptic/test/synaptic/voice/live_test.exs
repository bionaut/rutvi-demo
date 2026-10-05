defmodule Synaptic.Voice.LiveTest do
  use ExUnit.Case, async: false
  alias Synaptic.Voice
  alias Synaptic.Voice.Providers.OpenAI.Live.SessionBootstrap

  defmodule Workflow do
    use Synaptic.Workflow

    step :input, suspend: true, resume_schema: %{human_input_text: :string} do
      case get_in(context, [:human_input, :human_input_text]) do
        text when is_binary(text) -> {:ok, %{query: text}}
        _ -> suspend_for_human("Ask a question")
      end
    end

    step :answer do
      {:ok, %{assistant_answer: "Verified answer."}}
    end

    commit()
  end

  test "Live bootstrap uses server-side SDP exchange and only Live configuration" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/live", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["transport"] == %{"type" => "webrtc", "sdp" => "offer"}
      assert payload["session"]["model"] == "gpt-live-1"
      assert payload["session"]["delegation"] == %{"type" => "client"}
      assert payload["session"]["audio"] == %{"output" => %{"voice" => "marin"}}
      refute Map.has_key?(payload["session"], "reasoning")
      refute Map.has_key?(payload["session"], "tools")
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

      Plug.Conn.resp(
        conn,
        201,
        ~s({"session":{"id":"live_test"},"transport":{"type":"webrtc","sdp":"answer"}})
      )
    end)

    assert {:ok, transport} =
             SessionBootstrap.create_browser_bootstrap(
               sdp: "offer",
               api_key: "test-key",
               endpoint: "http://localhost:#{bypass.port}/live"
             )

    assert transport.sdp == "answer"
    assert transport.experience == :live
    refute Map.has_key?(transport, :client_secret)
  end

  test "missing SDP is rejected before credentials or HTTP, and creation errors are not retried" do
    assert {:error, :missing_sdp_offer} = SessionBootstrap.create_browser_bootstrap([])
    bypass = Bypass.open()
    Bypass.expect_once(bypass, "POST", "/live", &Plug.Conn.resp(&1, 503, "unavailable"))

    assert {:error, {:upstream_error, 503, _}} =
             SessionBootstrap.create_browser_bootstrap(
               sdp: "offer",
               api_key: "test-key",
               endpoint: "http://localhost:#{bypass.port}/live"
             )
  end

  test "explicit Live selection routes to a separate engine and bridges a real workflow" do
    session = start_live()
    assert session.transport.experience == :live

    assert {:ok, _, %{engine: Synaptic.Voice.Sessions.Live.OpenAI}} =
             Voice.Router.lookup(session.session_id)

    transcript(session, "Look up my order", "u1")
    delegate(session, "item_lookup")

    assert_receive {:synaptic_voice_event,
                    %{
                      event: :provider_outbound,
                      data: %{
                        event: %{
                          "type" => "session.commentary.append",
                          "delegation_id" => "item_lookup",
                          "content" => "Verified answer."
                        }
                      }
                    }},
                   2000

    assert Voice.inspect_session(session.session_id).engine_state.current_task_active == false
  end

  test "notice before transcript waits, exact fragments and timestamps reach backend, duplicate notices run once" do
    owner = self()

    session =
      start_live(
        live_delegate_fun: fn context ->
          send(owner, {:context, context})
          {:ok, "Found it."}
        end
      )

    delegate(session, "item_opaque")
    refute_receive {:context, _}, 50
    transcript(session, "Book", "u1", 0, 100)
    transcript(session, " Friday", "u2", 100, 200)
    delegate(session, "item_opaque")
    assert_receive {:context, context}, 1000
    assert Enum.map(context.transcript, & &1.text) == ["Book", " Friday"]
    assert Enum.map(context.transcript, & &1.start_ms) == [0, 100]
    assert context.delegation_id == "item_opaque"
    delegate(session, "item_opaque")
    refute_receive {:context, _}, 80
  end

  test "speech can overlap backend work and stale results cannot be spoken" do
    owner = self()

    session =
      start_live(
        live_delegate_fun: fn _ ->
          send(owner, {:worker, self()})

          receive do
            :finish -> {:ok, "Thursday is available."}
          end
        end
      )

    transcript(session, "Thursday", "u1")
    delegate(session, "item_thursday")
    assert_receive {:worker, worker}, 1000
    transcript(session, "Actually Friday", "u2")

    Voice.ingest_provider_event(session.session_id, %{
      "type" => "session.output_transcript.delta",
      "delta" => "Of course.",
      "event_id" => "a1"
    })

    assert_receive {:synaptic_voice_event,
                    %{event: :assistant_text_chunk, data: %{text: "Of course."}}}

    send(worker, :finish)
    assert_receive {:synaptic_voice_event, %{event: :delegation_superseded}}, 1000

    refute_receive {:synaptic_voice_event,
                    %{
                      event: :provider_outbound,
                      data: %{event: %{"content" => "Thursday is available."}}
                    }},
                   100
  end

  @tag capture_log: true
  test "a backend crash leaves the voice session alive and blocks uncertain retries" do
    session = start_live(live_delegate_fun: fn _ -> exit(:boom) end)
    transcript(session, "Do work", "u1")
    delegate(session, "item_crash")

    assert_receive {:synaptic_voice_event,
                    %{event: :session_error, data: %{reason: {:backend_exit, :boom}}}},
                   1000

    assert Voice.inspect_session(session.session_id).engine_state.blocked
    delegate(session, "item_retry")

    assert_receive {:synaptic_voice_event,
                    %{event: :session_error, data: %{reason: :backend_requires_reconciliation}}},
                   1000
  end

  test "backend timeout does not claim cancellation or allow a new overlapping operation" do
    session =
      start_live(
        workflow_timeout_ms: 40,
        live_delegate_fun: fn _ ->
          Process.sleep(200)
          {:ok, "Late"}
        end
      )

    transcript(session, "Work", "u1")
    delegate(session, "item_slow")

    assert_receive {:synaptic_voice_event,
                    %{event: :session_error, data: %{reason: :backend_timeout}}},
                   1000

    assert Voice.inspect_session(session.session_id).engine_state.blocked
  end

  test "usage is cumulative and close waits for finalization" do
    session = start_live()
    {:ok, pid, _} = Voice.Router.lookup(session.session_id)
    monitor = Process.monitor(pid)

    Voice.ingest_provider_event(session.session_id, %{
      "type" => "session.usage.updated",
      "usage" => %{"seconds" => 12}
    })

    Voice.ingest_provider_event(session.session_id, %{
      "type" => "session.usage.updated",
      "usage" => %{"seconds" => 15}
    })

    assert Voice.inspect_session(session.session_id).usage == %{"seconds" => 15}
    assert :ok = Voice.stop_session(session.session_id)
    assert Voice.inspect_session(session.session_id).status == :closing

    assert_receive {:synaptic_voice_event,
                    %{event: :provider_outbound, data: %{event: %{"type" => "session.close"}}}}

    Voice.ingest_provider_event(session.session_id, %{
      "type" => "session.closed",
      "usage" => %{"seconds" => 16},
      "reason" => "close_requested"
    })

    assert_receive {:synaptic_voice_event,
                    %{event: :session_usage, data: %{final: true, usage: %{"seconds" => 16}}}}

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "duplicate transcript events are ignored and oversize results are not truncated into speech" do
    session = start_live(live_delegate_fun: fn _ -> {:ok, String.duplicate("x", 501)} end)
    transcript(session, "Hello", "same")
    transcript(session, "Hello", "same")
    assert Voice.inspect_session(session.session_id).engine_state.revision == 1
    delegate(session, "item_large")

    assert_receive {:synaptic_voice_event,
                    %{event: :session_error, data: %{reason: :live_result_too_long}}},
                   1000
  end

  defp start_live(opts \\ []) do
    bootstrap = fn _ ->
      {:ok,
       %{
         session_id: "live_test",
         sdp: "answer",
         experience: :live,
         model: "gpt-live-1",
         voice: "marin"
       }}
    end

    opts =
      Keyword.merge(
        [
          mode: :realtime,
          provider: :openai,
          experience: :live,
          live_bootstrap_fun: bootstrap,
          live_context_settle_ms: 10,
          live_close_timeout_ms: 50
        ],
        opts
      )

    {:ok, session} = Voice.start_session(Workflow, %{}, opts)
    Voice.subscribe_session(session.session_id)

    Voice.ingest_provider_event(session.session_id, %{
      "type" => "session.started",
      "session" => %{"id" => "live_test"}
    })

    on_exit(fn ->
      try do
        Voice.client_disconnected(session.session_id)
      catch
        :exit, _ -> :ok
      end

      Synaptic.stop(session.run_id, :test_cleanup)
    end)

    session
  end

  defp transcript(session, text, id, start_ms \\ 0, end_ms \\ 100) do
    Voice.ingest_provider_event(session.session_id, %{
      "type" => "session.input_transcript.delta",
      "delta" => text,
      "event_id" => id,
      "start_ms" => start_ms,
      "end_ms" => end_ms
    })
  end

  defp delegate(session, id),
    do:
      Voice.ingest_provider_event(session.session_id, %{
        "type" => "session.delegation.created",
        "delegation" => %{"id" => id, "target" => "client"}
      })
end
