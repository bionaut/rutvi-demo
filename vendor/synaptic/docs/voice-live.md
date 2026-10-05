# GPT-Live voice sessions

GPT-Live 1 is an opt-in OpenAI voice integration. Existing Realtime, duplex,
turn-based, and Gemini callers keep their current defaults and event contracts.
Selecting `gpt-live-1` alone on a Realtime session is not enough: choose the Live
experience explicitly. This implementation supports **WebRTC with client
delegation**. Responses delegation, primary audio WebSockets, and a provider
sideband WebSocket are not implemented here.

## Connect a browser

Have the browser create a peer connection, attach microphone tracks, register an
`oai-events` data channel, create an SDP offer, and finish ICE gathering. Send the
offer to your application server. Keep the OpenAI API key on that server.

```elixir
{:ok, session} = Synaptic.Voice.start_session(MyApp.ConversationWorkflow, %{},
  mode: :realtime,
  provider: :openai,
  experience: :live,
  profile: MyApp.VoiceProfile,
  session_context: %{preferred_language: "en"},
  provider_opts: [realtime: [
    model: "gpt-live-1",
    voice: "marin",
    sdp: browser_offer
  ]]
)

Synaptic.Voice.subscribe_session(session.session_id)
# Return session.transport.sdp to the browser as its remote SDP answer.
```

The profile declares the fields accepted by `session_context`; omit both options
to use the default profile. Bootstrap calls `POST /v1/live/sessions` and requires
HTTP 201. It does not retry this billable creation request. `transport.session_id`
is OpenAI's opaque Live ID; `session.session_id` is Synaptic's local session ID.

Wait for `session.started`, not merely the data channel opening. Do not send
Realtime `session.update`, `response.create`, audio commits, or `session.start`.
WebRTC media tracks carry audio. Forward JSON provider events with
`Synaptic.Voice.ingest_provider_event/2`. Forward the `data.event` from each
`:provider_outbound` envelope back onto the data channel exactly once, in order.
Subscribe and attach the browser to its application session **before** applying
the SDP answer so early events cannot race the subscription.

As with the existing lab, this browser relay is a development integration. A
production host must authenticate sessions and enforce ownership of inbound
events; do not treat browser-supplied provider events as proof of authorization.

## Connect the backend

The default backend resumes the attached Synaptic workflow at a human checkpoint
with `%{human_input_text: role_labelled_conversation}`. It waits for the next human
checkpoint or completion and reads `:assistant_answer` (or `:answer`, `:response`,
`:reply`). Workflows remain responsible for their business rules, tool permissions,
confirmations, and operation idempotency.

Live delegation is not a structured function call. It supplies an opaque ID, not
task text or tool arguments. Synaptic retains a rolling window of 2,000 transcript
fragments, preserving exact text and timing. It waits for user context and a short
settling interval (350 ms by default). This delay is only a delivery heuristic,
not proof of a complete sentence. Use `live_context_fun` for stronger
application-specific readiness checks; subscribe to transcript events if your
application needs the full history or persistence.

To connect a different agent or an application backend:

```elixir
live_delegate_fun: fn snapshot ->
  # snapshot includes run_id, session_id, delegation_id, revision, transcript,
  # timeout_ms, session_context, authorized capabilities, and security_policy.
  MyApp.VoiceBackend.run(snapshot) # => {:ok, concise_verified_text} | {:error, reason}
end,
live_context_fun: fn snapshot ->
  # A fast, non-blocking callback. A subsequent user fragment retries :wait.
  if MyApp.RequestContext.ready?(snapshot), do: {:ok, snapshot}, else: :wait
end
```

Profile capabilities are filtered using existing session authorization. Their
descriptions are available to the voice model and their definitions to the
backend callback. They are **not** executed automatically by the Live engine.
An application backend selecting direct capabilities should call
`Synaptic.Voice.CapabilityGateway.execute/5` and preserve application confirmation
checks. `approve_capability/2` is not supported by this engine: backend
confirmation is separate from the voice stream.

Backend output must be 1–500 UTF-8 bytes. This conservative bound fits the API's
500-token append limit without adding a tokenizer. Longer results return
`:live_result_too_long`; they are never silently truncated. Summarize inside the
backend before returning. Output is sent as `session.commentary.append`; actual
spoken text comes from the provider's output transcript, not this result.

## Corrections, failures, and lifecycle

- Delegation IDs and provider event IDs suppress duplicate delivery. Only one
  backend task runs at a time; up to 32 delegation notices can wait.
- New user transcript text increments a revision. If it changes while a backend
  runs, the result is withheld and `:delegation_superseded` is emitted. This is
  deliberately conservative: even a short acknowledgment may invalidate an
  answer. It does not automatically rerun or reverse an action.
- Backend tasks are supervised without linking their failures to the voice
  process. A timeout or crash blocks further execution for that session, since
  the operation's outcome may be unknown. Reconcile application state before
  creating a replacement session. Stopping a waiter does not cancel a workflow.
- User and assistant speech may overlap. `:input_transcript_delta` and
  `:assistant_text_chunk` carry exact fragments and timestamps. There is no fake
  `:input_final_text` or `:assistant_response_done` event. Keep playback status
  separate from transcript and workflow progress.
- `stop_session/2` requests `session.close` and enters `:closing`. Keep receiving
  and forwarding events until `session.closed`. `:session_usage` has cumulative
  usage and `final: true` only after that final event. The engine then stops.
- A lost connection or a 15-second close timeout stops the session with final
  usage unconfirmed. Workflow state is independent and in-memory; it is not
  persisted across application restarts. Automatic reconnect/replay is not used.
- `push_audio`, `push_text`, `end_turn`, and `cancel_output` are not supported for
  this WebRTC integration. Microphone and playback controls belong in the client.

## Voice lab

The local demo is `tmp/voice_lab` (underscore), and remains gitignored. It uses
the repository through a path dependency. Start it with `OPENAI_API_KEY` set:

```sh
cd tmp/voice_lab
mix assets.build
VOICE_LAB_PORT=4011 mix phx.server
```

Open `http://localhost:4011`, select **OpenAI → Realtime → GPT-Live 1**, then
connect. Realtime 2.1 and mini remain available for comparison. Live uses Marin;
the existing Realtime demo uses Verse. The interview profile is preserved, with
no application tools enabled. If reasoning is delegated, `VoiceLab.Workflow`
remains the backend. The UI hides Realtime-only reasoning and conversation mode
controls when Live is selected.

Try interrupting the greeting, overlapping speech, a multi-part answer, a
correction while backend work runs, disconnecting, and reconnecting. Compare
both spoken behavior and transcript/event logs. Mocked tests validate protocol
and lifecycle behavior; real model access, microphone behavior, and spoken
quality require this manual test.

Official references: [Live WebRTC](https://developers.openai.com/api/docs/guides/voice-webrtc?api=live),
[client delegation](https://developers.openai.com/api/docs/guides/live-delegation),
[session lifecycle](https://developers.openai.com/api/docs/guides/live-conversations).
