defmodule Synaptic.Voice.Sessions.Live.OpenAI do
  @moduledoc false
  # GPT-Live is opt-in and uses its own lifecycle. Realtime keeps its existing
  # turn semantics; this engine bridges continuous speech to client delegation.
  use GenServer

  alias Synaptic.Voice.{Event, Profile, SessionContext, SessionRegistry}
  alias Synaptic.Voice.Providers.OpenAI.Live.{ProfileCompiler, SessionBootstrap, WorkflowBridge}

  def child_spec(opts),
    do: %{
      id: {__MODULE__, opts[:session_id]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }

  def start_link(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: SessionRegistry.via(opts[:session_id], opts[:registry_metadata])
      )

  def inspect_session(pid), do: GenServer.call(pid, :inspect)
  def ingest_provider_event(pid, payload), do: GenServer.call(pid, {:event, payload})
  def client_connected(pid, _meta), do: GenServer.call(pid, :connected)
  def client_disconnected(pid, _meta), do: GenServer.call(pid, :disconnected)
  def stop_session(pid, reason), do: GenServer.call(pid, {:close, reason})
  def push_audio(_pid, _chunk, _opts), do: {:error, :webrtc_media_required}
  def push_text(_pid, _text, _opts), do: {:error, :unsupported_for_mode}
  def end_turn(_pid, _opts), do: {:error, :continuous_audio_session}
  def cancel_output(_pid), do: {:error, :client_playback_control_required}
  def playback_drained(_pid), do: :ok
  def approve_capability(_pid, _name), do: {:error, :backend_confirmation_required}

  @impl true
  def init(opts) do
    profile = resolve_profile(Keyword.get(opts, :profile, Profile.default()))

    context =
      SessionContext.new!(profile.context_schema, opts[:session_context] || %{},
        authorization: opts[:session_authorization] || %{}
      )

    compiled = ProfileCompiler.compile(profile, context)
    {_provider, realtime_opts} = opts[:stack_opts].realtime

    bootstrap_opts =
      Keyword.put(
        realtime_opts,
        :instructions,
        Enum.join([compiled.instructions, realtime_opts[:instructions] || ""], "\n")
      )

    bootstrap = opts[:live_bootstrap_fun] || (&SessionBootstrap.create_browser_bootstrap/1)

    with {:ok, transport} <- bootstrap.(bootstrap_opts),
         {:ok, task_supervisor} <- Task.Supervisor.start_link() do
      state = %{
        session_id: opts[:session_id],
        run_id: opts[:run_id],
        transport: transport,
        status: :connecting,
        seq: 0,
        started: false,
        closing: false,
        profile: profile,
        context: context,
        capabilities: compiled.capabilities,
        delegate: opts[:live_delegate_fun] || (&WorkflowBridge.run/1),
        context_fun: opts[:live_context_fun],
        timeout_ms: opts[:workflow_timeout_ms] || 30_000,
        settle_ms: opts[:live_context_settle_ms] || 350,
        close_timeout_ms: opts[:live_close_timeout_ms] || 15_000,
        transcript: [],
        revision: 0,
        events: MapSet.new(),
        delegations: MapSet.new(),
        queue: [],
        current: nil,
        settle_timer: nil,
        usage: nil,
        blocked: false,
        task_supervisor: task_supervisor
      }

      Process.send_after(self(), :startup_timeout, opts[:live_startup_timeout_ms] || 30_000)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:inspect, _from, state) do
    {:reply,
     %{
       session_id: state.session_id,
       run_id: state.run_id,
       mode: :realtime,
       experience: :live,
       status: state.status,
       transport: state.transport,
       usage: state.usage,
       engine_state: %{
         revision: state.revision,
         current_task_active: state.current != nil,
         queued_delegations: length(state.queue),
         blocked: state.blocked
       }
     }, state}
  end

  # A WebRTC data channel opening is not proof that the Live session has started.
  def handle_call(:connected, _from, state), do: {:reply, :ok, state}

  def handle_call(:disconnected, _from, state) do
    state =
      emit(state, :session_error, %{
        source: :transport,
        reason: :live_connection_lost,
        final_usage_confirmed: false
      })

    {:stop, :normal, :ok, state}
  end

  def handle_call({:close, _reason}, _from, %{closing: true} = state), do: {:reply, :ok, state}

  def handle_call({:close, _reason}, _from, state) do
    state = begin_close(state)
    {:reply, :ok, state}
  end

  def handle_call({:event, payload}, _from, state) do
    if duplicate?(state, payload) do
      {:reply, :ok, state}
    else
      state = remember_event(state, payload)

      case process_event(payload, state) do
        {:stop, state} -> {:stop, :normal, :ok, state}
        state -> {:reply, :ok, state}
      end
    end
  end

  @impl true
  def handle_info({:settled, token}, %{settle_timer: {_timer, token}} = state) do
    {:noreply, maybe_delegate(%{state | settle_timer: nil})}
  end

  def handle_info({ref, result}, %{current: %{task: %{ref: ref}} = current} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(current.timer)
    state = %{state | current: nil}

    state =
      cond do
        state.closing ->
          state

        current.revision != state.revision ->
          state
          |> emit(:delegation_superseded, %{delegation_id: current.id, revision: current.revision})
          |> append(
            "thinking",
            current.id,
            "The conversation changed during backend work. Its previous answer has been withheld. Clarify the current request before delegating again; do not assume any action was cancelled."
          )

        true ->
          deliver_result(state, current.id, result)
      end

    {:noreply, schedule(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current: %{task: %{ref: ref}} = current} = state
      ) do
    Process.cancel_timer(current.timer)
    state = %{state | current: nil, blocked: true}
    {:noreply, backend_error(state, current.id, {:backend_exit, reason})}
  end

  def handle_info({:backend_timeout, ref}, %{current: %{task: %{ref: ref}} = current} = state) do
    Task.shutdown(current.task, :brutal_kill)
    # Stopping the waiter does not cancel a workflow or reverse its side effects.
    state = %{state | current: nil, blocked: true}
    {:noreply, backend_error(state, current.id, :backend_timeout)}
  end

  def handle_info(:startup_timeout, %{started: false} = state) do
    {:stop, :normal,
     emit(state, :session_error, %{source: :transport, reason: :live_startup_timeout})}
  end

  def handle_info(:close_timeout, state) do
    {:stop, :normal,
     emit(state, :session_error, %{
       source: :transport,
       reason: :live_close_timeout,
       final_usage_confirmed: false
     })}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if state.current, do: Task.shutdown(state.current.task, :brutal_kill)
    cancel_settle(state)
    if Process.alive?(state.task_supervisor), do: Supervisor.stop(state.task_supervisor)
    emit(state, :session_stopped, %{reason: inspect(reason), usage: state.usage})
    :ok
  end

  defp process_event(%{"type" => "session.started", "session" => %{"id" => id}}, state) do
    cond do
      state.started ->
        state

      id != state.transport.session_id ->
        emit(state, :session_error, %{source: :provider, reason: :live_session_id_mismatch})

      true ->
        %{state | started: true, status: :listening}
        |> emit(:session_started, %{mode: :realtime, experience: :live})
        |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})
        |> schedule()
    end
  end

  defp process_event(%{"type" => type, "delta" => text} = payload, state)
       when type in ["session.input_transcript.delta", "session.output_transcript.delta"] and
              is_binary(text) do
    role = if type == "session.input_transcript.delta", do: :user, else: :assistant
    fragment = %{role: role, text: text, start_ms: payload["start_ms"], end_ms: payload["end_ms"]}
    state = %{state | transcript: Enum.take(state.transcript ++ [fragment], -2_000)}

    if role == :user do
      %{state | revision: state.revision + 1}
      |> emit(:input_transcript_delta, fragment)
      |> schedule()
    else
      emit(state, :assistant_text_chunk, fragment)
    end
  end

  defp process_event(
         %{
           "type" => "session.delegation.created",
           "delegation" => %{"id" => id, "target" => "client"}
         },
         state
       )
       when is_binary(id) and byte_size(id) > 0 do
    cond do
      state.closing or MapSet.member?(state.delegations, id) ->
        state

      length(state.queue) >= 32 ->
        backend_error(state, id, :delegation_queue_full)

      true ->
        %{state | delegations: MapSet.put(state.delegations, id), queue: state.queue ++ [id]}
        |> emit(:delegation_requested, %{delegation_id: id})
        |> schedule()
    end
  end

  defp process_event(%{"type" => "session.usage.updated", "usage" => usage}, state),
    do: emit(%{state | usage: usage}, :session_usage, %{usage: usage, final: false})

  defp process_event(%{"type" => "session.closed"} = payload, state) do
    state = %{state | usage: payload["usage"], closing: true}

    {:stop,
     emit(state, :session_usage, %{usage: state.usage, final: true, reason: payload["reason"]})}
  end

  defp process_event(%{"type" => "error", "error" => error}, state),
    do: emit(state, :session_error, %{source: :provider, reason: error})

  defp process_event(%{"type" => type, "client_event_id" => id}, state)
       when type in [
              "session.commentary.appended",
              "session.thinking.appended",
              "session.instructions.appended"
            ],
       do: emit(state, :live_update_accepted, %{type: type, client_event_id: id})

  defp process_event(_payload, state), do: state

  defp maybe_delegate(%{current: current} = state) when not is_nil(current), do: state
  defp maybe_delegate(%{closing: true} = state), do: state
  defp maybe_delegate(%{started: false} = state), do: state
  defp maybe_delegate(%{queue: []} = state), do: state

  defp maybe_delegate(%{blocked: true, queue: [id | rest]} = state),
    do: backend_error(%{state | queue: rest}, id, :backend_requires_reconciliation)

  defp maybe_delegate(%{queue: [id | rest]} = state) do
    context = %{
      run_id: state.run_id,
      session_id: state.session_id,
      delegation_id: id,
      revision: state.revision,
      transcript: state.transcript,
      timeout_ms: state.timeout_ms,
      session_context: state.context,
      capabilities: state.capabilities,
      security_policy: state.profile.security_policy
    }

    readiness =
      if state.context_fun do
        state.context_fun.(context)
      else
        if Enum.any?(state.transcript, &(&1.role == :user and String.trim(&1.text) != "")),
          do: {:ok, context},
          else: :wait
      end

    case readiness do
      {:ok, prepared} when is_map(prepared) ->
        delegate = state.delegate

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            delegate.(prepared)
          end)

        timer = Process.send_after(self(), {:backend_timeout, task.ref}, state.timeout_ms)

        %{
          state
          | current: %{id: id, revision: state.revision, task: task, timer: timer},
            queue: rest
        }
        |> emit(:workflow_started, %{delegation_id: id, revision: state.revision})
        |> append("thinking", id, "The backend has started work. No result is verified yet.")

      :wait ->
        emit(state, :delegation_waiting_for_context, %{delegation_id: id})

      {:error, reason} ->
        backend_error(%{state | queue: rest}, id, reason)
    end
  end

  defp deliver_result(state, id, {:ok, text}) when is_binary(text) do
    # UTF-8 bytes conservatively bound the append to <= 500 tokens, without
    # truncating a result into a potentially misleading partial statement.
    if byte_size(text) in 1..500 do
      state |> append("commentary", id, text) |> emit(:workflow_finished, %{delegation_id: id})
    else
      backend_error(state, id, :live_result_too_long)
    end
  end

  defp deliver_result(state, id, {:error, :workflow_timeout}),
    do: backend_error(%{state | blocked: true}, id, :workflow_timeout)

  defp deliver_result(state, id, {:error, reason}), do: backend_error(state, id, reason)
  defp deliver_result(state, id, _), do: backend_error(state, id, :invalid_backend_result)

  defp backend_error(state, id, reason) do
    state = emit(state, :session_error, %{source: :workflow, reason: reason, delegation_id: id})

    if state.closing do
      state
    else
      append(
        state,
        "commentary",
        id,
        "The backend could not provide a verified result. Do not claim the task succeeded or was cancelled. Ask the user how to proceed."
      )
    end
  end

  defp append(state, kind, id, content),
    do:
      outbound(state, %{
        "type" => "session.#{kind}.append",
        "event_id" => "synaptic_#{state.session_id}_#{state.seq}",
        "delegation_id" => id,
        "content" => content
      })

  defp outbound(state, event), do: emit(state, :provider_outbound, %{event: event})

  defp begin_close(state) do
    Process.send_after(self(), :close_timeout, state.close_timeout_ms)

    %{state | closing: true, status: :closing}
    |> outbound(%{"type" => "session.close"})
    |> emit(:duplex_state_changed, %{status: :closing, mode: :realtime})
  end

  defp schedule(%{queue: []} = state), do: state

  defp schedule(state) do
    cancel_settle(state)
    token = make_ref()
    timer = Process.send_after(self(), {:settled, token}, state.settle_ms)
    %{state | settle_timer: {timer, token}}
  end

  defp cancel_settle(%{settle_timer: {timer, _}}), do: Process.cancel_timer(timer)
  defp cancel_settle(_), do: :ok

  defp duplicate?(state, %{"event_id" => id}) when is_binary(id),
    do: MapSet.member?(state.events, id)

  defp duplicate?(_state, _payload), do: false

  defp remember_event(state, %{"event_id" => id}) when is_binary(id) do
    events = if MapSet.size(state.events) >= 20_000, do: MapSet.new(), else: state.events
    %{state | events: MapSet.put(events, id)}
  end

  defp remember_event(state, _), do: state

  defp emit(state, name, data) do
    event = Event.build(state.session_id, state.run_id, state.seq + 1, name, data)

    Phoenix.PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:voice:session:" <> state.session_id,
      {:synaptic_voice_event, event}
    )

    %{state | seq: state.seq + 1}
  end

  defp resolve_profile(%Profile{} = profile), do: Profile.new!(profile)
  defp resolve_profile(module) when is_atom(module), do: module.profile() |> Profile.new!()
  defp resolve_profile(attrs), do: Profile.new!(attrs)
end
