defmodule Synaptic.Tools do
  @moduledoc """
  Helper utilities for invoking LLM providers from workflow steps.
  """

  require Logger

  alias Synaptic.{
    ActionControls,
    Audit,
    ContextHygiene,
    Factuality,
    MCP,
    MCP.Connection,
    MCPGovernance,
    PolicyHooks,
    Privacy,
    PromptSecurity,
    Security,
    SecurityPolicy,
    Sanitization,
    ToolPolicy,
    Validation
  }

  alias Synaptic.Tools.Tool

  @default_adapter Synaptic.Tools.OpenAI

  @doc """
  Dispatches a chat completion request to the configured adapter.

  Pass `agent: :name` to pull default options (model, temperature, adapter,
  etc.) from the `:agents` configuration. Provide `tools: [...]` with
  `%Synaptic.Tools.Tool{}` structs (or maps/keywords convertible via
  `Synaptic.Tools.Tool.new/1`) to enable tool-calling flows. Provide `mcp: [...]`
  with MCP server descriptors to expose remote tools and MCP resource browsing.

  When `stream: true` is passed, the response will be streamed and PubSub events
  will be emitted for each chunk. Note: streaming automatically falls back to
  non-streaming mode when tools are provided, as OpenAI streaming doesn't support
  tool calling.
  """
  def chat(messages, opts \\ []) when is_list(messages) do
    {agent_name, agent_opts, call_opts} = agent_options(opts)

    merged_opts =
      agent_opts
      |> Keyword.merge(call_opts)
      |> maybe_put_tool_policy_agent(agent_name)

    with {:ok, merged_opts, security_report} <- Security.prepare_opts(:chat, merged_opts) do
      hygiene_state = ContextHygiene.new(merged_opts)
      privacy_state = Privacy.new(merged_opts)
      sanitization_state = Sanitization.new(merged_opts)
      prompt_security_state = PromptSecurity.new(merged_opts)
      policy_state = ToolPolicy.new(merged_opts)
      action_state = ActionControls.new(merged_opts)
      factuality_state = Factuality.new(merged_opts)
      audit_state = Audit.new(merged_opts)
      hooks_config = PolicyHooks.new(merged_opts)

      {tools, merged_opts} = Keyword.pop(merged_opts, :tools, [])
      {mcp_entries, merged_opts} = Keyword.pop(merged_opts, :mcp, [])

      local_tools = normalize_tools(tools)

      with {:ok, registry_entries, llm_specs} <-
             build_tool_registry(local_tools, mcp_entries, merged_opts) do
        adapter = Keyword.get(merged_opts, :adapter, configured_adapter())
        stream_enabled = Keyword.get(merged_opts, :stream, false)
        tools_present? = registry_entries != []
        factuality_requires_buffering? = Factuality.requires_buffering?(factuality_state)

        audit_state =
          Audit.record(
            :chat,
            :request_prepared,
            %{
              model: Keyword.get(merged_opts, :model, "unknown"),
              stream: stream_enabled,
              message_count: length(messages),
              tool_count: length(registry_entries)
            },
            audit_state
          )

        if stream_enabled and (tools_present? or factuality_requires_buffering?) do
          require Logger

          cond do
            tools_present? ->
              Logger.warning(
                "Streaming requested but tools are provided. Falling back to non-streaming mode (OpenAI limitation)."
              )

            factuality_requires_buffering? ->
              Logger.warning(
                "Streaming requested with factuality output checks enabled. Falling back to non-streaming mode so the final response can be verified before release."
              )
          end

          adapter_opts =
            merged_opts
            |> Keyword.delete(:stream)
            |> maybe_put_adapter_tools(llm_specs)

          adapter
          |> do_chat(
            messages,
            adapter_opts,
            registry_entries,
            hygiene_state,
            privacy_state,
            sanitization_state,
            prompt_security_state,
            policy_state,
            action_state,
            factuality_state,
            audit_state,
            hooks_config
          )
          |> finalize_result(security_report)
        else
          adapter_opts = maybe_put_adapter_tools(merged_opts, llm_specs)

          if stream_enabled do
            adapter
            |> do_chat_stream(
              messages,
              adapter_opts,
              hygiene_state,
              privacy_state,
              sanitization_state,
              prompt_security_state,
              policy_state,
              action_state,
              factuality_state,
              audit_state,
              hooks_config
            )
            |> finalize_result(security_report)
          else
            adapter
            |> do_chat(
              messages,
              adapter_opts,
              registry_entries,
              hygiene_state,
              privacy_state,
              sanitization_state,
              prompt_security_state,
              policy_state,
              action_state,
              factuality_state,
              audit_state,
              hooks_config
            )
            |> finalize_result(security_report)
          end
        end
      end
    end
  end

  defp finalize_result(
         {result, hygiene_state, privacy_state, prompt_security_state, policy_state, action_state,
          factuality_state, audit_state},
         security_report
       ) do
    audit_state =
      record_chat_completion(
        result,
        hygiene_state,
        privacy_state,
        prompt_security_state,
        policy_state,
        action_state,
        factuality_state,
        audit_state
      )

    result
    |> Privacy.finalize_result(privacy_state)
    |> PromptSecurity.finalize_result(prompt_security_state)
    |> Factuality.finalize_result(factuality_state)
    |> ContextHygiene.finalize_result(hygiene_state)
    |> ToolPolicy.finalize_result(policy_state)
    |> ActionControls.finalize_result(action_state)
    |> Audit.finalize_result(audit_state)
    |> Security.maybe_attach_metadata(security_report)
  end

  defp do_chat(
         adapter,
         messages,
         opts,
         [],
         hygiene_state,
         privacy_state,
         sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state,
         hooks_config
       ),
       do:
         do_chat_with_privacy(
           adapter,
           messages,
           opts,
           hygiene_state,
           privacy_state,
           sanitization_state,
           prompt_security_state,
           policy_state,
           action_state,
           factuality_state,
           audit_state,
           hooks_config
         )

  defp do_chat(
         adapter,
         messages,
         opts,
         registry_entries,
         hygiene_state,
         privacy_state,
         sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state,
         hooks_config
       ) do
    max_tool_rounds = Keyword.get(opts, :max_tool_rounds, 8)

    do_chat(
      adapter,
      messages,
      opts,
      registry_entries,
      max_tool_rounds,
      hygiene_state,
      privacy_state,
      sanitization_state,
      prompt_security_state,
      policy_state,
      action_state,
      factuality_state,
      audit_state,
      hooks_config
    )
  end

  defp do_chat(
         adapter,
         messages,
         opts,
         registry_entries,
         remaining_tool_rounds,
         hygiene_state,
         privacy_state,
         sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state,
         hooks_config
       ) do
    registry = Map.new(registry_entries, &{&1.llm_name, &1})

    case do_chat_with_privacy(
           adapter,
           messages,
           opts,
           hygiene_state,
           privacy_state,
           sanitization_state,
           prompt_security_state,
           policy_state,
           action_state,
           factuality_state,
           audit_state,
           hooks_config
         ) do
      {{:ok, %{tool_calls: tool_calls} = message}, updated_hygiene_state, updated_privacy_state,
       updated_prompt_security_state, updated_policy_state, updated_action_state,
       updated_factuality_state, updated_audit_state}
      when is_list(tool_calls) and tool_calls != [] ->
        continue_after_tool_calls(
          adapter,
          messages,
          message,
          tool_calls,
          registry,
          opts,
          registry_entries,
          remaining_tool_rounds,
          updated_hygiene_state,
          updated_privacy_state,
          sanitization_state,
          updated_prompt_security_state,
          updated_policy_state,
          updated_action_state,
          updated_factuality_state,
          updated_audit_state,
          hooks_config
        )

      {{:ok, %{tool_calls: tool_calls} = message, _usage}, updated_hygiene_state,
       updated_privacy_state, updated_prompt_security_state, updated_policy_state,
       updated_action_state, updated_factuality_state, updated_audit_state}
      when is_list(tool_calls) and tool_calls != [] ->
        continue_after_tool_calls(
          adapter,
          messages,
          message,
          tool_calls,
          registry,
          opts,
          registry_entries,
          remaining_tool_rounds,
          updated_hygiene_state,
          updated_privacy_state,
          sanitization_state,
          updated_prompt_security_state,
          updated_policy_state,
          updated_action_state,
          updated_factuality_state,
          updated_audit_state,
          hooks_config
        )

      {{:ok, %{"tool_calls" => tool_calls} = message}, updated_hygiene_state,
       updated_privacy_state, updated_prompt_security_state, updated_policy_state,
       updated_action_state, updated_factuality_state, updated_audit_state}
      when is_list(tool_calls) and tool_calls != [] ->
        continue_after_tool_calls(
          adapter,
          messages,
          message,
          tool_calls,
          registry,
          opts,
          registry_entries,
          remaining_tool_rounds,
          updated_hygiene_state,
          updated_privacy_state,
          sanitization_state,
          updated_prompt_security_state,
          updated_policy_state,
          updated_action_state,
          updated_factuality_state,
          updated_audit_state,
          hooks_config
        )

      {{:ok, %{"tool_calls" => tool_calls} = message, _usage}, updated_hygiene_state,
       updated_privacy_state, updated_prompt_security_state, updated_policy_state,
       updated_action_state, updated_factuality_state, updated_audit_state}
      when is_list(tool_calls) and tool_calls != [] ->
        continue_after_tool_calls(
          adapter,
          messages,
          message,
          tool_calls,
          registry,
          opts,
          registry_entries,
          remaining_tool_rounds,
          updated_hygiene_state,
          updated_privacy_state,
          sanitization_state,
          updated_prompt_security_state,
          updated_policy_state,
          updated_action_state,
          updated_factuality_state,
          updated_audit_state,
          hooks_config
        )

      other ->
        other
    end
  end

  defp continue_after_tool_calls(
         _adapter,
         _messages,
         _message,
         tool_calls,
         _registry,
         _opts,
         _registry_entries,
         remaining_tool_rounds,
         hygiene_state,
         privacy_state,
         _sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state,
         _hooks_config
       )
       when remaining_tool_rounds <= 0 do
    {{:error, {:max_tool_rounds_exceeded, tool_call_names(tool_calls)}}, hygiene_state,
     privacy_state, prompt_security_state, policy_state, action_state, factuality_state,
     audit_state}
  end

  defp continue_after_tool_calls(
         adapter,
         messages,
         message,
         _tool_calls,
         registry,
         opts,
         registry_entries,
         remaining_tool_rounds,
         hygiene_state,
         privacy_state,
         sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state,
         hooks_config
       ) do
    {new_messages, updated_hygiene_state, updated_privacy_state, updated_prompt_security_state,
     updated_policy_state, updated_action_state, updated_factuality_state,
     updated_audit_state} =
      apply_tool_calls(
        messages,
        message,
        registry,
        opts,
        hygiene_state,
        privacy_state,
        sanitization_state,
        prompt_security_state,
        policy_state,
        action_state,
        factuality_state,
        audit_state,
        hooks_config
      )

    do_chat(
      adapter,
      new_messages,
      opts,
      registry_entries,
      remaining_tool_rounds - 1,
      updated_hygiene_state,
      updated_privacy_state,
      sanitization_state,
      updated_prompt_security_state,
      updated_policy_state,
      updated_action_state,
      updated_factuality_state,
      updated_audit_state,
      hooks_config
    )
  end

  defp do_chat_with_privacy(
         adapter,
         messages,
         opts,
         hygiene_state,
         privacy_state,
         sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state,
         hooks_config
       ) do
    {prepared_messages, updated_hygiene_state} =
      ContextHygiene.prepare_messages(messages, hygiene_state)

    {prepared_messages, updated_privacy_state} =
      Privacy.prepare_messages(prepared_messages, privacy_state)

    audit_state =
      maybe_record_privacy_audit(
        audit_state,
        privacy_state,
        updated_privacy_state,
        :pii_detected,
        %{reason: "prompt_preparation"}
      )

    audit_state =
      maybe_record_privacy_audit(
        audit_state,
        privacy_state,
        updated_privacy_state,
        :pii_transformed,
        %{reason: "prompt_preparation"}
      )

    {prepared_messages, _updated_sanitization_state} =
      Sanitization.prepare_messages(prepared_messages, sanitization_state)

    with {:ok, prepared_messages, updated_prompt_security_state} <-
           PromptSecurity.prepare_messages(prepared_messages, prompt_security_state) do
      {prepared_messages, updated_factuality_state} =
        Factuality.prepare_messages(prepared_messages, factuality_state)

      with {:allow, _security_trace} <-
             SecurityPolicy.authorize_prompt(opts, updated_privacy_state),
           {:ok, hooked_messages} <-
             run_pre_prompt_hooks(prepared_messages, adapter, opts, hooks_config) do
        updated_audit_state =
          maybe_record_privacy_audit(
            audit_state,
            privacy_state,
            updated_privacy_state,
            :pii_transmitted,
            %{reason: "model_prompt_release"}
          )

        updated_audit_state =
          Audit.record(
            :chat,
            :prompt_prepared,
            prompt_audit_metadata(hooked_messages, opts, updated_hygiene_state),
            updated_audit_state
          )

        adapter
        |> do_chat_with_telemetry(hooked_messages, opts, [])
        |> Privacy.sanitize_result(updated_privacy_state)
        |> then(fn {result, latest_privacy_state} ->
          case run_post_output_hooks(result, adapter, opts, hooks_config) do
            {:ok, hooked_result} ->
              maybe_apply_factuality(hooked_result, updated_factuality_state)
              |> then(fn {factuality_result, latest_factuality_state} ->
                {factuality_result, updated_hygiene_state, latest_privacy_state,
                 updated_prompt_security_state, policy_state, action_state,
                 latest_factuality_state, updated_audit_state}
              end)

            {:error, reason} ->
              {{:error, reason}, updated_hygiene_state, latest_privacy_state,
               updated_prompt_security_state, policy_state, action_state,
               updated_factuality_state, updated_audit_state}
          end
        end)
      else
        {:deny, trace} ->
          updated_audit_state =
            maybe_record_privacy_audit(
              audit_state,
              privacy_state,
              updated_privacy_state,
              :pii_blocked,
              %{reason: trace.reason}
            )

          {{:error, {:security_policy_failed, trace}}, updated_hygiene_state,
           updated_privacy_state, updated_prompt_security_state, policy_state, action_state,
           updated_factuality_state, updated_audit_state}

        {:ask, trace} ->
          updated_audit_state =
            maybe_record_privacy_audit(
              audit_state,
              privacy_state,
              updated_privacy_state,
              :pii_blocked,
              %{reason: trace.reason}
            )

          {{:error, {:security_policy_failed, trace}}, updated_hygiene_state,
           updated_privacy_state, updated_prompt_security_state, policy_state, action_state,
           updated_factuality_state, updated_audit_state}

        {:error, reason} ->
          {{:error, reason}, updated_hygiene_state, updated_privacy_state,
           updated_prompt_security_state, policy_state, action_state, updated_factuality_state,
           audit_state}
      end
    else
      {:error, reason, updated_prompt_security_state} ->
        {{:error, reason}, updated_hygiene_state, updated_privacy_state,
         updated_prompt_security_state, policy_state, action_state, factuality_state, audit_state}
    end
  end

  defp do_chat_with_telemetry(adapter, messages, opts, _tools) do
    run_id = Keyword.get(opts, :run_id) || get_from_context(:__run_id__)
    step_name = Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    model = Keyword.get(opts, :model) || "unknown"
    stream = Keyword.get(opts, :stream, false)

    metadata = %{
      run_id: run_id,
      step_name: step_name,
      adapter: adapter,
      model: model,
      stream: stream
    }

    :telemetry.span(
      [:synaptic, :llm],
      metadata,
      fn ->
        adapter_result = adapter.chat(messages, opts)
        updated_metadata = extract_telemetry_metadata(adapter_result, metadata)
        {strip_usage(adapter_result), updated_metadata}
      end
    )
  end

  defp extract_telemetry_metadata({:ok, _content, %{usage: usage}}, metadata)
       when is_map(usage) do
    metadata
    |> Map.put(:usage, usage)
    |> Map.put(
      :prompt_tokens,
      Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens") || 0
    )
    |> Map.put(
      :completion_tokens,
      Map.get(usage, :completion_tokens) || Map.get(usage, "completion_tokens") || 0
    )
    |> Map.put(
      :total_tokens,
      Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
    )
  end

  defp extract_telemetry_metadata({:ok, _content}, metadata), do: metadata
  defp extract_telemetry_metadata({:error, _reason}, metadata), do: metadata

  defp strip_usage({:ok, content, %{usage: _usage}}), do: {:ok, content}
  defp strip_usage({:ok, content, _other}), do: {:ok, content}
  defp strip_usage(other), do: other

  defp do_chat_stream(
         adapter,
         messages,
         opts,
         hygiene_state,
         privacy_state,
         sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state,
         hooks_config
       ) do
    run_id = Keyword.get(opts, :run_id) || get_from_context(:__run_id__)
    step_name = Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    model = Keyword.get(opts, :model) || "unknown"

    {prepared_messages, updated_hygiene_state} =
      ContextHygiene.prepare_messages(messages, hygiene_state)

    {prepared_messages, updated_privacy_state} =
      Privacy.prepare_messages(prepared_messages, privacy_state)

    audit_state =
      maybe_record_privacy_audit(
        audit_state,
        privacy_state,
        updated_privacy_state,
        :pii_detected,
        %{reason: "stream_prompt_preparation"}
      )

    audit_state =
      maybe_record_privacy_audit(
        audit_state,
        privacy_state,
        updated_privacy_state,
        :pii_transformed,
        %{reason: "stream_prompt_preparation"}
      )

    {prepared_messages, _updated_sanitization_state} =
      Sanitization.prepare_messages(prepared_messages, sanitization_state)

    with {:ok, prepared_messages, updated_prompt_security_state} <-
           PromptSecurity.prepare_messages(prepared_messages, prompt_security_state) do
      {prepared_messages, updated_factuality_state} =
        Factuality.prepare_messages(prepared_messages, factuality_state)

      stream_state_key = {:synaptic_privacy_stream, make_ref()}

      metadata = %{
        run_id: run_id,
        step_name: step_name,
        adapter: adapter,
        model: model,
        stream: true
      }

      Process.put(stream_state_key, "")

      on_chunk = fn _chunk, accumulated ->
        filtered_accumulated = Privacy.preview_stream_output(accumulated, updated_privacy_state)
        previous_filtered = Process.get(stream_state_key, "")

        filtered_chunk =
          if String.starts_with?(filtered_accumulated, previous_filtered) do
            String.replace_prefix(filtered_accumulated, previous_filtered, "")
          else
            filtered_accumulated
          end

        Process.put(stream_state_key, filtered_accumulated)
        publish_stream_chunk(run_id, step_name, filtered_chunk, filtered_accumulated)
      end

      with {:allow, _security_trace} <-
             SecurityPolicy.authorize_prompt(opts, updated_privacy_state),
           {:ok, hooked_messages} <-
             run_pre_prompt_hooks(prepared_messages, adapter, opts, hooks_config) do
        updated_audit_state =
          maybe_record_privacy_audit(
            audit_state,
            privacy_state,
            updated_privacy_state,
            :pii_transmitted,
            %{reason: "stream_model_prompt_release"}
          )

        updated_audit_state =
          Audit.record(
            :chat,
            :prompt_prepared,
            prompt_audit_metadata(hooked_messages, opts, updated_hygiene_state),
            updated_audit_state
          )

        adapter_opts = Keyword.put(opts, :on_chunk, on_chunk)

        result =
          :telemetry.span(
            [:synaptic, :llm],
            metadata,
            fn ->
              adapter_result = adapter.chat(hooked_messages, adapter_opts)

              case adapter_result do
                {:ok, accumulated} = ok_result ->
                  filtered_accumulated =
                    Privacy.preview_stream_output(accumulated, updated_privacy_state)

                  if run_id do
                    publish_stream_done(run_id, step_name, filtered_accumulated)
                  end

                  {ok_result, metadata}

                {:ok, accumulated, %{usage: usage}} = ok_result ->
                  filtered_accumulated =
                    Privacy.preview_stream_output(accumulated, updated_privacy_state)

                  if run_id do
                    publish_stream_done(run_id, step_name, filtered_accumulated)
                  end

                  updated_metadata =
                    metadata
                    |> Map.put(:usage, usage)
                    |> Map.put(
                      :prompt_tokens,
                      Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens") || 0
                    )
                    |> Map.put(
                      :completion_tokens,
                      Map.get(usage, :completion_tokens) ||
                        Map.get(usage, "completion_tokens") || 0
                    )
                    |> Map.put(
                      :total_tokens,
                      Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
                    )

                  {ok_result, updated_metadata}

                error ->
                  {error, metadata}
              end
            end
          )

        Process.delete(stream_state_key)

        {sanitized_result, latest_privacy_state} =
          Privacy.sanitize_result(result, updated_privacy_state)

        case run_post_output_hooks(sanitized_result, adapter, opts, hooks_config) do
          {:ok, hooked_result} ->
            maybe_apply_factuality(hooked_result, updated_factuality_state)
            |> then(fn {factuality_result, latest_factuality_state} ->
              {factuality_result, updated_hygiene_state, latest_privacy_state,
               updated_prompt_security_state, policy_state, action_state, latest_factuality_state,
               updated_audit_state}
            end)

          {:error, reason} ->
            {{:error, reason}, updated_hygiene_state, latest_privacy_state,
             updated_prompt_security_state, policy_state, action_state, updated_factuality_state,
             updated_audit_state}
        end
      else
        {:deny, trace} ->
          Process.delete(stream_state_key)

          updated_audit_state =
            maybe_record_privacy_audit(
              audit_state,
              privacy_state,
              updated_privacy_state,
              :pii_blocked,
              %{reason: trace.reason}
            )

          {{:error, {:security_policy_failed, trace}}, updated_hygiene_state,
           updated_privacy_state, updated_prompt_security_state, policy_state, action_state,
           updated_factuality_state, updated_audit_state}

        {:ask, trace} ->
          Process.delete(stream_state_key)

          updated_audit_state =
            maybe_record_privacy_audit(
              audit_state,
              privacy_state,
              updated_privacy_state,
              :pii_blocked,
              %{reason: trace.reason}
            )

          {{:error, {:security_policy_failed, trace}}, updated_hygiene_state,
           updated_privacy_state, updated_prompt_security_state, policy_state, action_state,
           updated_factuality_state, updated_audit_state}

        {:error, reason} ->
          Process.delete(stream_state_key)

          {{:error, reason}, updated_hygiene_state, updated_privacy_state,
           updated_prompt_security_state, policy_state, action_state, updated_factuality_state,
           audit_state}
      end
    else
      {:error, reason, updated_prompt_security_state} ->
        {{:error, reason}, updated_hygiene_state, updated_privacy_state,
         updated_prompt_security_state, policy_state, action_state, factuality_state, audit_state}
    end
  end

  defp get_from_context(key) do
    case Process.get({:synaptic_context, key}) do
      nil -> nil
      value -> value
    end
  end

  defp publish_stream_chunk(nil, _step_name, _chunk, _accumulated), do: :ok

  defp publish_stream_chunk(run_id, step_name, chunk, accumulated) do
    alias Phoenix.PubSub

    event = %{
      event: :stream_chunk,
      step: step_name,
      chunk: chunk,
      accumulated: accumulated,
      run_id: run_id,
      current_step: step_name
    }

    PubSub.broadcast(Synaptic.PubSub, "synaptic:run:" <> run_id, {:synaptic_event, event})
  end

  defp publish_stream_done(nil, _step_name, _accumulated), do: :ok

  defp publish_stream_done(run_id, step_name, accumulated) do
    alias Phoenix.PubSub

    event = %{
      event: :stream_done,
      step: step_name,
      accumulated: accumulated,
      run_id: run_id,
      current_step: step_name
    }

    PubSub.broadcast(Synaptic.PubSub, "synaptic:run:" <> run_id, {:synaptic_event, event})
  end

  defp agent_options(opts) do
    {agent_name, remaining_opts} = Keyword.pop(opts, :agent)

    agent_opts =
      case agent_name do
        nil -> []
        name -> lookup_agent_opts(name)
      end

    {agent_name, agent_opts, remaining_opts}
  end

  defp lookup_agent_opts(name) do
    agents = configured_agents()
    key = agent_key(name)

    case Map.fetch(agents, key) do
      {:ok, opts} -> opts
      :error -> raise ArgumentError, "unknown Synaptic agent #{inspect(name)}"
    end
  end

  defp configured_agents do
    Application.get_env(:synaptic, __MODULE__, [])
    |> Keyword.get(:agents, %{})
    |> normalize_agents()
  end

  defp configured_adapter do
    Application.get_env(:synaptic, __MODULE__, [])
    |> Keyword.get(:llm_adapter, @default_adapter)
  end

  defp normalize_agents(%{} = agents) do
    Enum.reduce(agents, %{}, fn {name, opts}, acc ->
      Map.put(acc, agent_key(name), normalize_agent_opts(opts))
    end)
  end

  defp normalize_agents(list) when is_list(list) do
    Enum.reduce(list, %{}, fn {name, opts}, acc ->
      Map.put(acc, agent_key(name), normalize_agent_opts(opts))
    end)
  end

  defp normalize_agents(_), do: %{}

  defp normalize_agent_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "agent options must be a keyword list, got: #{inspect(opts)}"
    end
  end

  defp normalize_agent_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_agent_opts()
  end

  defp normalize_agent_opts(other) do
    raise ArgumentError, "agent options must be a keyword list, got: #{inspect(other)}"
  end

  defp agent_key(name) when is_atom(name), do: Atom.to_string(name)
  defp agent_key(name) when is_binary(name) and byte_size(name) > 0, do: name

  defp agent_key(name) do
    raise ArgumentError, "agent names must be atoms or strings, got: #{inspect(name)}"
  end

  defp normalize_tools([]), do: []

  defp normalize_tools(tools) when is_list(tools) do
    Enum.map(tools, &Tool.new/1)
  end

  defp normalize_tools(tool), do: [Tool.new(tool)]

  defp build_tool_registry(local_tools, mcp_entries, opts) do
    validation_enabled? = tool_validation_enabled?(opts)

    with {:ok, local_registry} <- build_local_registry(local_tools, validation_enabled?),
         {:ok, connections} <- MCP.normalize_connections(mcp_entries, opts),
         {:ok, governed_connections} <- MCPGovernance.authorize_connections(connections, opts),
         {:ok, mcp_registry} <-
           build_mcp_registry(governed_connections, opts, validation_enabled?),
         {:ok, registry} <-
           merge_registry_entries(local_registry, mcp_registry) do
      {:ok, registry, Enum.map(registry, & &1.llm_spec)}
    end
  end

  defp build_local_registry(local_tools, validation_enabled?) do
    Enum.reduce_while(local_tools, {:ok, []}, fn tool, {:ok, acc} ->
      case compile_tool_schema(tool.schema, validation_enabled?) do
        {:ok, compiled_schema} ->
          entry = %{
            llm_name: tool.name,
            llm_spec: %{
              type: "function",
              function: %{
                name: tool.name,
                description: tool.description,
                parameters: compiled_schema.adapter_schema
              }
            },
            dispatch: {:local, tool},
            compiled_schema: compiled_schema,
            source: %{type: :local, server: nil, remote_name: tool.name},
            metadata: Tool.metadata(tool)
          }

          {:cont, {:ok, acc ++ [entry]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_tool_schema, tool.name, reason}}}
      end
    end)
  end

  defp build_mcp_registry([], _opts, _validation_enabled?), do: {:ok, []}

  defp build_mcp_registry(connections, opts, validation_enabled?) do
    hooks_config = PolicyHooks.new(opts)

    connections
    |> uniquify_server_names()
    |> Enum.reduce_while({:ok, []}, fn connection, {:ok, acc} ->
      case run_pre_mcp_hook(:discover, connection, opts, hooks_config) do
        {:error, reason} ->
          {:halt, {:error, {:mcp_hook_blocked, connection.name, reason}}}

        {:ok, connection} ->
          discover_mcp_connection(connection, opts, validation_enabled?, acc)
      end
    end)
  end

  defp discover_mcp_connection(connection, opts, validation_enabled?, acc) do
    case MCP.discover(connection, opts) do
      {:ok, discovery} ->
        maybe_log_mcp_discovery(connection, discovery, opts)

        with {:ok, tool_entries} <-
               build_mcp_tool_entries(connection, discovery.tools, validation_enabled?),
             {:ok, resource_entries} <-
               build_mcp_resource_entries(
                 connection,
                 discovery.resources_supported?,
                 validation_enabled?
               ) do
          {:ok, acc ++ tool_entries ++ resource_entries}
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:mcp_discovery_failed, connection.name, reason}}
    end
    |> case do
      {:ok, entries} -> {:cont, {:ok, entries}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp uniquify_server_names(connections) do
    {reversed, _counts} =
      Enum.reduce(connections, {[], %{}}, fn %Connection{name: name} = connection,
                                             {acc, counts} ->
        count = Map.get(counts, name, 0) + 1
        unique_name = if count == 1, do: name, else: "#{name}_#{count}"
        {[Map.put(connection, :name, unique_name) | acc], Map.put(counts, name, count)}
      end)

    Enum.reverse(reversed)
  end

  defp build_mcp_tool_entries(connection, tools, validation_enabled?) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      remote_name = tool_name(tool)
      llm_name = "#{connection.name}__#{remote_name}"

      case compile_tool_schema(tool_input_schema(tool), validation_enabled?) do
        {:ok, compiled_schema} ->
          entry = %{
            llm_name: llm_name,
            llm_spec: %{
              type: "function",
              function: %{
                name: llm_name,
                description: tool_description(tool),
                parameters: compiled_schema.adapter_schema
              }
            },
            dispatch: {:mcp_tool, connection, remote_name},
            compiled_schema: compiled_schema,
            source: %{type: :mcp, server: connection.name, remote_name: remote_name},
            metadata: ToolPolicy.default_metadata(:mcp_tool, %{})
          }

          {:cont, {:ok, acc ++ [entry]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_mcp_tool_schema, connection.name, remote_name, reason}}}
      end
    end)
  end

  defp build_mcp_resource_entries(_connection, false, _validation_enabled?), do: {:ok, []}

  defp build_mcp_resource_entries(connection, true, validation_enabled?) do
    list_resources_schema = %{type: "object", properties: %{}}

    read_resource_schema = %{
      type: "object",
      properties: %{
        uri: %{type: "string", minLength: 1, description: "The resource URI to read."}
      },
      required: ["uri"]
    }

    with {:ok, compiled_list_resources_schema} <-
           compile_tool_schema(list_resources_schema, validation_enabled?),
         {:ok, compiled_read_resource_schema} <-
           compile_tool_schema(read_resource_schema, validation_enabled?) do
      {:ok,
       [
         %{
           llm_name: "#{connection.name}__list_resources",
           llm_spec: %{
             type: "function",
             function: %{
               name: "#{connection.name}__list_resources",
               description: "Lists resources available from the #{connection.name} MCP server.",
               parameters: compiled_list_resources_schema.adapter_schema
             }
           },
           dispatch: {:mcp_list_resources, connection},
           compiled_schema: compiled_list_resources_schema,
           source: %{type: :mcp, server: connection.name, remote_name: "list_resources"},
           metadata: ToolPolicy.default_metadata(:mcp_resource, %{})
         },
         %{
           llm_name: "#{connection.name}__read_resource",
           llm_spec: %{
             type: "function",
             function: %{
               name: "#{connection.name}__read_resource",
               description: "Reads one resource from the #{connection.name} MCP server by URI.",
               parameters: compiled_read_resource_schema.adapter_schema
             }
           },
           dispatch: {:mcp_read_resource, connection},
           compiled_schema: compiled_read_resource_schema,
           source: %{type: :mcp, server: connection.name, remote_name: "read_resource"},
           metadata: ToolPolicy.default_metadata(:mcp_resource, %{})
         }
       ]}
    else
      {:error, reason} ->
        {:error, {:invalid_mcp_resource_schema, connection.name, reason}}
    end
  end

  defp merge_registry_entries(local_registry, mcp_registry) do
    all_entries = local_registry ++ mcp_registry

    all_entries
    |> Enum.reduce_while({:ok, MapSet.new()}, fn entry, {:ok, seen} ->
      if MapSet.member?(seen, entry.llm_name) do
        {:halt, {:error, {:duplicate_tool_name, entry.llm_name}}}
      else
        {:cont, {:ok, MapSet.put(seen, entry.llm_name)}}
      end
    end)
    |> case do
      {:ok, _seen} -> {:ok, all_entries}
      error -> error
    end
  end

  defp maybe_put_adapter_tools(opts, []), do: opts
  defp maybe_put_adapter_tools(opts, llm_specs), do: Keyword.put(opts, :tools, llm_specs)

  defp tool_name(tool) do
    Map.get(tool, :name) || Map.get(tool, "name") || ""
  end

  defp tool_description(tool) do
    Map.get(tool, :description) || Map.get(tool, "description") || ""
  end

  defp tool_input_schema(tool) do
    Map.get(tool, :input_schema) ||
      Map.get(tool, "input_schema") ||
      Map.get(tool, "inputSchema") ||
      %{type: "object", properties: %{}}
  end

  defp compile_tool_schema(schema, validation_enabled?) do
    Validation.compile_json_schema(schema, validate_schema: validation_enabled?)
  end

  defp tool_validation_enabled?(opts) do
    opts
    |> Keyword.get(:validation)
    |> normalize_tool_validation()
  end

  defp normalize_tool_validation(nil), do: Validation.default_tool_validation()
  defp normalize_tool_validation(false), do: false
  defp normalize_tool_validation(true), do: true

  defp normalize_tool_validation(%{} = validation) do
    validation
    |> Map.to_list()
    |> normalize_tool_validation()
  end

  defp normalize_tool_validation(validation) when is_list(validation) do
    Keyword.get(validation, :tools, Validation.default_tool_validation())
  end

  defp apply_tool_calls(
         messages,
         message,
         registry,
         opts,
         hygiene_state,
         privacy_state,
         sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state,
         hooks_config
       ) do
    assistant_msg = %{
      role: "assistant",
      content: Map.get(message, :content) || Map.get(message, "content"),
      tool_calls: Map.get(message, :tool_calls) || Map.get(message, "tool_calls")
    }

    {tool_messages,
     {updated_hygiene_state, updated_privacy_state, updated_prompt_security_state,
      updated_policy_state, updated_action_state, updated_factuality_state,
      updated_audit_state}} =
      Enum.map_reduce(
        assistant_msg.tool_calls,
        {hygiene_state, privacy_state, prompt_security_state, policy_state, action_state,
         factuality_state, audit_state},
        fn call,
           {current_hygiene_state, current_privacy_state, current_prompt_security_state,
            current_policy_state, current_action_state, current_factuality_state,
            current_audit_state} ->
          execute_tool_call(
            call,
            registry,
            opts,
            current_hygiene_state,
            current_privacy_state,
            sanitization_state,
            current_prompt_security_state,
            current_policy_state,
            current_action_state,
            current_factuality_state,
            current_audit_state,
            hooks_config
          )
        end
      )

    {messages ++ [assistant_msg | tool_messages], updated_hygiene_state, updated_privacy_state,
     updated_prompt_security_state, updated_policy_state, updated_action_state,
     updated_factuality_state, updated_audit_state}
  end

  defp execute_tool_call(
         call,
         registry,
         opts,
         hygiene_state,
         privacy_state,
         sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state,
         hooks_config
       ) do
    function = Map.get(call, "function") || Map.get(call, :function) || %{}
    name = Map.get(function, "name") || Map.get(function, :name)
    raw_args = Map.get(function, "arguments") || Map.get(function, :arguments) || "{}"
    id = Map.get(call, "id") || Map.get(call, :id)
    entry = Map.fetch!(registry, name)

    requested_audit_state =
      Audit.record(
        :tool,
        :tool_call_requested,
        tool_audit_metadata(entry, :requested),
        audit_state
      )

    {result, updated_hygiene_state, updated_privacy_state, updated_prompt_security_state,
     updated_policy_state, updated_action_state, updated_factuality_state,
     updated_audit_state} =
      with {:ok, args} <- decode_tool_args(raw_args),
           resolved_args <- Privacy.rehydrate_tool_args(args, privacy_state),
           {sanitized_args, _updated_sanitization_state} <-
             Sanitization.sanitize_tool_args(resolved_args, sanitization_state),
           :ok <- validate_tool_arguments(entry, sanitized_args) do
        case PromptSecurity.authorize_tool_call(entry, opts, prompt_security_state) do
          {:allow, latest_prompt_security_state} ->
            case allow_tool_call(entry, sanitized_args, opts, policy_state) do
              {:allow, _trace, latest_policy_state} ->
                case SecurityPolicy.authorize_tool(entry, opts, privacy_state) do
                  {:allow, _security_trace} ->
                    case run_pre_tool_hooks(entry, sanitized_args, opts, hooks_config) do
                      {:ok, hooked_args} ->
                        {result, latest_action_state} =
                          ActionControls.dispatch(
                            entry,
                            hooked_args,
                            opts,
                            action_state,
                            fn -> dispatch_tool_call(entry, hooked_args, opts, hooks_config) end
                          )

                        case run_post_tool_hooks(entry, hooked_args, result, opts, hooks_config) do
                          {:ok, hooked_result} ->
                            finalize_tool_result(
                              entry,
                              hooked_result,
                              hygiene_state,
                              privacy_state,
                              sanitization_state,
                              latest_prompt_security_state,
                              latest_policy_state,
                              latest_action_state,
                              factuality_state,
                              requested_audit_state
                            )

                          {:error, {:hook_denied, surface, reason}} ->
                            finalize_tool_result(
                              entry,
                              hook_result_payload(entry, surface, reason),
                              hygiene_state,
                              privacy_state,
                              sanitization_state,
                              latest_prompt_security_state,
                              latest_policy_state,
                              latest_action_state,
                              factuality_state,
                              requested_audit_state
                            )

                          {:error, {:hook_failure, surface, reason}} ->
                            finalize_tool_result(
                              entry,
                              hook_failure_payload(entry, surface, reason),
                              hygiene_state,
                              privacy_state,
                              sanitization_state,
                              latest_prompt_security_state,
                              latest_policy_state,
                              latest_action_state,
                              factuality_state,
                              requested_audit_state
                            )
                        end

                      {:error, {:hook_denied, surface, reason}} ->
                        finalize_tool_result(
                          entry,
                          hook_result_payload(entry, surface, reason),
                          hygiene_state,
                          privacy_state,
                          sanitization_state,
                          latest_prompt_security_state,
                          latest_policy_state,
                          action_state,
                          factuality_state,
                          requested_audit_state
                        )

                      {:error, {:hook_failure, surface, reason}} ->
                        finalize_tool_result(
                          entry,
                          hook_failure_payload(entry, surface, reason),
                          hygiene_state,
                          privacy_state,
                          sanitization_state,
                          latest_prompt_security_state,
                          latest_policy_state,
                          action_state,
                          factuality_state,
                          requested_audit_state
                        )
                    end

                  {decision, trace} when decision in [:deny, :ask] ->
                    finalize_tool_result(
                      entry,
                      policy_result_payload(entry, trace),
                      hygiene_state,
                      privacy_state,
                      sanitization_state,
                      latest_prompt_security_state,
                      latest_policy_state,
                      action_state,
                      factuality_state,
                      requested_audit_state
                    )
                end

              {{decision, trace}, latest_policy_state} when decision in [:deny, :ask] ->
                finalize_tool_result(
                  entry,
                  policy_result_payload(entry, trace),
                  hygiene_state,
                  privacy_state,
                  sanitization_state,
                  latest_prompt_security_state,
                  latest_policy_state,
                  action_state,
                  factuality_state,
                  requested_audit_state
                )
            end

          {:deny, trace, latest_prompt_security_state} ->
            finalize_tool_result(
              entry,
              policy_result_payload(entry, trace),
              hygiene_state,
              privacy_state,
              sanitization_state,
              latest_prompt_security_state,
              policy_state,
              action_state,
              factuality_state,
              requested_audit_state
            )
        end
      else
        {:error, issues} ->
          finalize_tool_result(
            entry,
            invalid_arguments_payload(entry, issues),
            hygiene_state,
            privacy_state,
            sanitization_state,
            prompt_security_state,
            policy_state,
            action_state,
            factuality_state,
            requested_audit_state
          )
      end

    {tool_message(id, name, result),
     {updated_hygiene_state, updated_privacy_state, updated_prompt_security_state,
      updated_policy_state, updated_action_state, updated_factuality_state, updated_audit_state}}
  end

  defp dispatch_tool_call(%{dispatch: {:local, tool}}, args, _opts, _hooks_config) do
    tool.handler.(args)
  end

  defp dispatch_tool_call(
         %{dispatch: {:mcp_tool, connection, remote_name}} = entry,
         args,
         opts,
         hooks_config
       ) do
    with {:ok, {hooked_connection, hooked_args}} <-
           run_pre_mcp_action_hook(:call_tool, connection, args, opts, hooks_config) do
      maybe_log_mcp_request(entry, hooked_args, opts)

      case MCP.call_tool(hooked_connection, remote_name, hooked_args, opts) do
        {:ok, result} ->
          maybe_log_mcp_result(entry, {:ok, result}, opts)
          normalize_mcp_result(result)

        {:error, reason} ->
          maybe_log_mcp_result(entry, {:error, reason}, opts)
          mcp_error_payload(entry, "tool_call_failed", inspect(reason))
      end
    else
      {:error, {:hook_denied, surface, reason}} -> hook_result_payload(entry, surface, reason)
      {:error, {:hook_failure, surface, reason}} -> hook_failure_payload(entry, surface, reason)
    end
  end

  defp dispatch_tool_call(
         %{dispatch: {:mcp_list_resources, connection}} = entry,
         _args,
         opts,
         hooks_config
       ) do
    with {:ok, {hooked_connection, _hooked_args}} <-
           run_pre_mcp_action_hook(:list_resources, connection, %{}, opts, hooks_config) do
      maybe_log_mcp_request(entry, %{}, opts)

      case MCP.list_resources(hooked_connection, opts) do
        {:ok, resources} ->
          maybe_log_mcp_result(entry, {:ok, resources}, opts)
          resources

        {:error, reason} ->
          maybe_log_mcp_result(entry, {:error, reason}, opts)
          mcp_error_payload(entry, "tool_call_failed", inspect(reason))
      end
    else
      {:error, {:hook_denied, surface, reason}} -> hook_result_payload(entry, surface, reason)
      {:error, {:hook_failure, surface, reason}} -> hook_failure_payload(entry, surface, reason)
    end
  end

  defp dispatch_tool_call(
         %{dispatch: {:mcp_read_resource, connection}} = entry,
         args,
         opts,
         hooks_config
       ) do
    with {:ok, {hooked_connection, hooked_args}} <-
           run_pre_mcp_action_hook(:read_resource, connection, args, opts, hooks_config) do
      uri = Map.get(hooked_args, "uri") || Map.get(hooked_args, :uri)

      maybe_log_mcp_request(entry, %{"uri" => uri}, opts)

      case MCP.read_resource(hooked_connection, uri, opts) do
        {:ok, result} ->
          maybe_log_mcp_result(entry, {:ok, result}, opts)
          normalize_mcp_result(result)

        {:error, reason} ->
          maybe_log_mcp_result(entry, {:error, reason}, opts)
          mcp_error_payload(entry, "tool_call_failed", inspect(reason))
      end
    else
      {:error, {:hook_denied, surface, reason}} -> hook_result_payload(entry, surface, reason)
      {:error, {:hook_failure, surface, reason}} -> hook_failure_payload(entry, surface, reason)
    end
  end

  defp decode_tool_args(raw_args) when is_map(raw_args), do: {:ok, raw_args}

  defp decode_tool_args(raw_args) when is_binary(raw_args) do
    case Jason.decode(raw_args) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, Validation.invalid_json_issue()}
      _ -> {:error, Validation.invalid_json_issue()}
    end
  end

  defp decode_tool_args(_), do: {:error, Validation.invalid_json_issue()}

  defp validate_tool_arguments(%{compiled_schema: compiled_schema}, args) do
    Validation.validate_json_arguments(compiled_schema, args)
  end

  defp invalid_arguments_payload(entry, issues) do
    %{
      error: true,
      source: entry.source.type,
      code: "invalid_arguments",
      message: "Tool arguments failed validation.",
      details: issues,
      server: entry.source.server,
      tool: entry.source.remote_name
    }
  end

  defp finalize_tool_result(
         entry,
         result,
         hygiene_state,
         privacy_state,
         sanitization_state,
         prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state
       ) do
    {sanitized_result, _updated_sanitization_state} =
      Sanitization.sanitize_tool_result(result, sanitization_state)

    {protected_result, updated_privacy_state} =
      Privacy.sanitize_tool_result(
        sanitized_result,
        privacy_state,
        tool_result_source_kind(entry)
      )

    audit_state =
      maybe_record_privacy_audit(
        audit_state,
        privacy_state,
        updated_privacy_state,
        :pii_detected,
        %{reason: "tool_result_processing"}
      )

    audit_state =
      maybe_record_privacy_audit(
        audit_state,
        privacy_state,
        updated_privacy_state,
        :pii_transformed,
        %{reason: "tool_result_processing"}
      )

    {prepared_result, updated_hygiene_state} =
      ContextHygiene.prepare_tool_result(entry, protected_result, hygiene_state)

    updated_factuality_state =
      Factuality.note_tool_result(entry, prepared_result, factuality_state)

    updated_audit_state =
      Audit.record(
        :tool,
        tool_audit_event(prepared_result),
        tool_audit_metadata(entry, tool_audit_status(prepared_result), prepared_result),
        audit_state
      )

    {prepared_result, updated_hygiene_state, updated_privacy_state, prompt_security_state,
     policy_state, action_state, updated_factuality_state, updated_audit_state}
  end

  defp normalize_mcp_result(%{"content" => content}) when is_binary(content), do: content
  defp normalize_mcp_result(%{content: content}) when is_binary(content), do: content

  defp normalize_mcp_result(%{"contents" => [%{"text" => text}]}) when is_binary(text), do: text
  defp normalize_mcp_result(%{contents: [%{text: text}]}) when is_binary(text), do: text

  defp normalize_mcp_result(result), do: result

  defp mcp_error_payload(entry, code, message) do
    %{
      error: true,
      source: :mcp,
      code: code,
      message: message,
      server: entry.source.server,
      tool: entry.source.remote_name
    }
  end

  defp tool_result_source_kind(%{dispatch: {:mcp_read_resource, _connection}}), do: :mcp_resource
  defp tool_result_source_kind(%{dispatch: {:mcp_list_resources, _connection}}), do: :mcp_resource
  defp tool_result_source_kind(_entry), do: :tool_derived

  defp encode_tool_result(result) when is_binary(result), do: result
  defp encode_tool_result(result), do: Jason.encode!(result)

  defp run_pre_prompt_hooks(messages, adapter, opts, hooks_config) do
    payload = %{
      messages: messages,
      adapter: adapter,
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      step_name: Keyword.get(opts, :step_name) || get_from_context(:__step_name__),
      model: Keyword.get(opts, :model) || "unknown"
    }

    case PolicyHooks.run(:pre_prompt, payload, hooks_config) do
      {:ok, updated_payload} ->
        {:ok,
         Map.get(updated_payload, :messages) || Map.get(updated_payload, "messages") || messages}

      error ->
        error
    end
  end

  defp run_post_output_hooks(result, adapter, opts, hooks_config) do
    payload = %{
      result: result,
      adapter: adapter,
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      step_name: Keyword.get(opts, :step_name) || get_from_context(:__step_name__),
      model: Keyword.get(opts, :model) || "unknown"
    }

    case PolicyHooks.run(:post_output, payload, hooks_config) do
      {:ok, updated_payload} ->
        {:ok, Map.get(updated_payload, :result) || Map.get(updated_payload, "result") || result}

      error ->
        error
    end
  end

  defp run_pre_tool_hooks(entry, args, opts, hooks_config) do
    payload = %{
      entry: entry,
      args: args,
      tool: entry.source.remote_name,
      qualified_tool: entry.llm_name,
      source: entry.source.type,
      server: entry.source.server,
      metadata: entry.metadata,
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      step_name: Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    }

    case PolicyHooks.run(:pre_tool, payload, hooks_config) do
      {:ok, updated_payload} ->
        {:ok, Map.get(updated_payload, :args) || Map.get(updated_payload, "args") || args}

      error ->
        error
    end
  end

  defp run_post_tool_hooks(entry, args, result, opts, hooks_config) do
    payload = %{
      entry: entry,
      args: args,
      result: result,
      tool: entry.source.remote_name,
      qualified_tool: entry.llm_name,
      source: entry.source.type,
      server: entry.source.server,
      metadata: entry.metadata,
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      step_name: Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    }

    case PolicyHooks.run(:post_tool, payload, hooks_config) do
      {:ok, updated_payload} ->
        {:ok, Map.get(updated_payload, :result) || Map.get(updated_payload, "result") || result}

      error ->
        error
    end
  end

  defp run_pre_mcp_hook(action, connection, opts, hooks_config) do
    payload = %{
      action: action,
      connection: connection,
      server: connection.name,
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      step_name: Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    }

    case PolicyHooks.run(:pre_mcp, payload, hooks_config) do
      {:ok, updated_payload} ->
        {:ok,
         Map.get(updated_payload, :connection) || Map.get(updated_payload, "connection") ||
           connection}

      error ->
        error
    end
  end

  defp maybe_apply_factuality({:ok, content} = result, %{} = state) when is_map(content) do
    if tool_call_response?(content) do
      {result, state}
    else
      Factuality.evaluate_result(result, state)
    end
  end

  defp maybe_apply_factuality({:ok, content, _meta} = result, %{} = state) when is_map(content) do
    if tool_call_response?(content) do
      {result, state}
    else
      Factuality.evaluate_result(result, state)
    end
  end

  defp maybe_apply_factuality(result, %{} = state), do: Factuality.evaluate_result(result, state)

  defp tool_call_response?(%{tool_calls: tool_calls}) when is_list(tool_calls),
    do: tool_calls != []

  defp tool_call_response?(%{"tool_calls" => tool_calls}) when is_list(tool_calls),
    do: tool_calls != []

  defp tool_call_response?(_content), do: false

  defp record_chat_completion(
         result,
         hygiene_state,
         privacy_state,
         _prompt_security_state,
         policy_state,
         action_state,
         factuality_state,
         audit_state
       ) do
    Audit.record(
      :guardrail,
      :chat_completed,
      %{
        status: completion_status(result),
        detection_count: privacy_detection_count(privacy_state),
        detection_types: privacy_detection_types(privacy_state),
        policy_decision_count: policy_decision_count(policy_state),
        record_count: action_event_count(action_state),
        spill_count: spill_count(hygiene_state),
        issue_codes: factuality_issue_codes(factuality_state),
        issue_count: factuality_issue_count(factuality_state),
        supported: factuality_supported?(factuality_state),
        factuality_action: factuality_action(result)
      },
      audit_state
    )
  end

  defp prompt_audit_metadata(messages, opts, hygiene_state) do
    prompt_context = Map.get(hygiene_state, :prompt_context)

    %{
      model: Keyword.get(opts, :model) || "unknown",
      message_count: length(messages),
      static_count: prompt_context && Map.get(prompt_context, :static_count),
      compacted_tool_messages: prompt_context && Map.get(prompt_context, :compacted_tool_messages)
    }
  end

  defp tool_audit_event(result) do
    case tool_audit_status(result) do
      :blocked -> :tool_call_blocked
      _ -> :tool_call_executed
    end
  end

  defp tool_audit_metadata(entry, status, result \\ nil) do
    metadata = entry.metadata || %{}

    %{
      tool: entry.source.remote_name,
      server: entry.source.server,
      source: entry.source.type,
      status: status,
      blocked: status == :blocked,
      decision: result_decision(result),
      reason: result_reason(result),
      spill_count: if(spilled_preview?(result), do: 1, else: 0),
      managed_only: Map.get(metadata, :managed_only)
    }
  end

  defp tool_audit_status(%{error: true}), do: :blocked
  defp tool_audit_status(%{"error" => true}), do: :blocked
  defp tool_audit_status(_result), do: :executed

  defp spilled_preview?(%{"kind" => "synaptic_tool_result_preview"}), do: true
  defp spilled_preview?(%{kind: "synaptic_tool_result_preview"}), do: true
  defp spilled_preview?(_result), do: false

  defp result_decision(%{decision: decision}), do: decision
  defp result_decision(%{"decision" => decision}), do: decision
  defp result_decision(_result), do: nil

  defp result_reason(%{reason: reason}), do: reason
  defp result_reason(%{"reason" => reason}), do: reason
  defp result_reason(_result), do: nil

  defp maybe_record_privacy_audit(
         audit_state,
         previous_privacy_state,
         next_privacy_state,
         event,
         extra_metadata
       ) do
    previous_count = privacy_detection_count(previous_privacy_state)
    next_count = privacy_detection_count(next_privacy_state)

    if next_count > previous_count do
      Audit.record(
        :guardrail,
        event,
        %{
          detection_count: next_count - previous_count,
          detection_types: privacy_detection_types(next_privacy_state),
          sensitivity_levels: privacy_detection_sensitivities(next_privacy_state),
          provenance: privacy_detection_provenance(next_privacy_state)
        }
        |> Map.merge(extra_metadata),
        audit_state
      )
    else
      audit_state
    end
  end

  defp privacy_detection_count(%{detections: detections}) when is_list(detections),
    do: length(detections)

  defp privacy_detection_count(_state), do: 0

  defp privacy_detection_types(%{detections: detections}) when is_list(detections) do
    detections
    |> Enum.map(fn detection -> Map.get(detection, :type) || Map.get(detection, "type") end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp privacy_detection_types(_state), do: []

  defp privacy_detection_sensitivities(%{detections: detections}) when is_list(detections) do
    detections
    |> Enum.map(fn detection ->
      Map.get(detection, :sensitivity) || Map.get(detection, "sensitivity")
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp privacy_detection_sensitivities(_state), do: []

  defp privacy_detection_provenance(%{detections: detections}) when is_list(detections) do
    detections
    |> Enum.map(fn detection ->
      Map.get(detection, :provenance) || Map.get(detection, "provenance")
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp privacy_detection_provenance(_state), do: []

  defp policy_decision_count(%{decisions: decisions}) when is_list(decisions),
    do: length(decisions)

  defp policy_decision_count(_state), do: 0

  defp action_event_count(%{events: events}) when is_list(events), do: length(events)
  defp action_event_count(_state), do: 0

  defp spill_count(%{spills: spills}) when is_list(spills), do: length(spills)
  defp spill_count(_state), do: 0

  defp factuality_issue_codes(%{issues: issues}) when is_list(issues) do
    issues
    |> Enum.map(fn issue -> Map.get(issue, :code) || Map.get(issue, "code") end)
    |> Enum.reject(&is_nil/1)
  end

  defp factuality_issue_codes(_state), do: []

  defp factuality_issue_count(state), do: length(factuality_issue_codes(state))

  defp factuality_supported?(%{issues: issues}) when is_list(issues), do: issues == []
  defp factuality_supported?(_state), do: true

  defp completion_status({:ok, _content}), do: :ok
  defp completion_status({:ok, _content, _meta}), do: :ok
  defp completion_status({:error, _reason}), do: :error
  defp completion_status(_result), do: :unknown

  defp factuality_action({:ok, content}) when is_binary(content) do
    if String.contains?(content, "I don't have enough evidence to answer that safely.") do
      :abstained
    else
      :released
    end
  end

  defp factuality_action({:error, {:factuality_failed, _issues}}), do: :failed
  defp factuality_action({:error, _reason}), do: :error
  defp factuality_action(_result), do: :released

  defp run_pre_mcp_action_hook(action, connection, args, opts, hooks_config) do
    payload = %{
      action: action,
      connection: connection,
      args: args,
      server: connection.name,
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      step_name: Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    }

    case PolicyHooks.run(:pre_mcp, payload, hooks_config) do
      {:ok, updated_payload} ->
        hooked_connection =
          Map.get(updated_payload, :connection) ||
            Map.get(updated_payload, "connection") ||
            connection

        hooked_args =
          Map.get(updated_payload, :args) ||
            Map.get(updated_payload, "args") ||
            args

        {:ok, {hooked_connection, hooked_args}}

      error ->
        error
    end
  end

  defp tool_message(id, name, result) do
    %{
      role: "tool",
      tool_call_id: id,
      name: name,
      content: encode_tool_result(result)
    }
  end

  defp allow_tool_call(entry, args, opts, policy_state) do
    case ToolPolicy.authorize(entry, args, opts, policy_state) do
      {:allow, trace, updated_policy_state} ->
        {:allow, trace, updated_policy_state}

      {decision, trace, updated_policy_state} when decision in [:deny, :ask] ->
        {{decision, trace}, updated_policy_state}
    end
  end

  defp policy_result_payload(entry, trace) do
    base = %{
      error: true,
      source: entry.source.type,
      server: entry.source.server,
      tool: entry.source.remote_name,
      decision: trace.decision,
      reason: trace.reason,
      trace: trace
    }

    case trace.decision do
      :deny ->
        Map.merge(base, %{
          code: "policy_denied",
          message: "Tool call denied by policy."
        })

      :ask ->
        Map.merge(base, %{
          code: "approval_required",
          message: "Tool call requires approval before execution."
        })
    end
  end

  defp hook_result_payload(entry, surface, reason) do
    %{
      error: true,
      source: entry.source.type,
      code: "hook_denied",
      message: "Hook blocked the action before execution.",
      surface: surface,
      reason: format_reason(reason),
      server: entry.source.server,
      tool: entry.source.remote_name
    }
  end

  defp hook_failure_payload(entry, surface, reason) do
    %{
      error: true,
      source: entry.source.type,
      code: "hook_failure",
      message: "Hook failed and the configured failure policy blocked execution.",
      surface: surface,
      reason: format_reason(reason),
      server: entry.source.server,
      tool: entry.source.remote_name
    }
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp maybe_put_tool_policy_agent(opts, nil), do: opts

  defp maybe_put_tool_policy_agent(opts, agent_name),
    do: Keyword.put(opts, :__tool_policy_agent__, agent_name)

  defp tool_call_names(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn call ->
      function = Map.get(call, "function") || Map.get(call, :function) || %{}
      Map.get(function, "name") || Map.get(function, :name) || "unknown_tool"
    end)
  end

  defp maybe_log_mcp_discovery(connection, discovery, opts) do
    if mcp_debug?(opts) do
      tool_names = Enum.map(discovery.tools, &tool_name/1)

      Logger.info(
        "[mcp] discovered server=#{connection.name} tools=#{inspect(tool_names)} resources_supported=#{discovery.resources_supported?}"
      )
    end
  end

  defp maybe_log_mcp_request(entry, payload, opts) do
    if mcp_debug?(opts) do
      Logger.info(
        "[mcp] request server=#{entry.source.server} tool=#{entry.source.remote_name} payload=#{truncate_for_log(payload)}"
      )
    end
  end

  defp maybe_log_mcp_result(entry, result, opts) do
    if mcp_debug?(opts) do
      Logger.info(
        "[mcp] result server=#{entry.source.server} tool=#{entry.source.remote_name} result=#{truncate_for_log(result)}"
      )
    end
  end

  defp mcp_debug?(opts) do
    Keyword.get(opts, :mcp_debug, false) || mcp_debug_from_config?()
  end

  defp mcp_debug_from_config? do
    Application.get_env(:synaptic, Synaptic.MCP, [])
    |> Keyword.get(:debug, false)
  end

  defp truncate_for_log(term) do
    inspected = inspect(term, pretty: false, limit: 20, printable_limit: 600)

    if String.length(inspected) > 700 do
      String.slice(inspected, 0, 700) <> "..."
    else
      inspected
    end
  end
end
