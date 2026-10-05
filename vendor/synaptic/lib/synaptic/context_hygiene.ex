defmodule Synaptic.ContextHygiene do
  @moduledoc false

  alias Synaptic.{Redaction, ToolResultStore}

  @preview_kind "synaptic_tool_result_preview"

  @default_config %{
    enabled: false,
    return_metadata: false,
    prompt: %{
      static_roles: ["system", "developer"]
    },
    tool_results: %{
      enabled: true,
      spill_oversized: true,
      compact_older: true,
      keep_recent: 2,
      max_inline_chars: 2_000,
      preview_chars: 320,
      store_ttl_ms: 15 * 60 * 1000,
      summarize_sensitive_previews: false,
      sensitive_preview_types: [:email, :phone, :ssn, :payment_card, :auth_token]
    }
  }

  @type state :: %{
          config: map(),
          spills: [map()],
          prompt_context: map() | nil,
          run_id: String.t() | nil,
          step_name: atom() | nil,
          tenant: String.t() | nil
        }

  def new(opts \\ []) when is_list(opts) do
    %{
      config: resolve_config(opts),
      spills: [],
      prompt_context: nil,
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      step_name: Keyword.get(opts, :step_name) || get_from_context(:__step_name__),
      tenant: Keyword.get(opts, :tenant) || get_from_context(:__tenant__)
    }
  end

  def enabled?(%{config: %{enabled: true}}), do: true
  def enabled?(_state), do: false

  def prepare_messages(messages, %{} = state) when is_list(messages) do
    if enabled?(state) do
      {prepared_messages, updated_state, compacted_count} = compact_messages(messages, state)

      prompt_context = %{
        static_count: count_static_messages(messages, state.config),
        dynamic_count: length(messages) - count_static_messages(messages, state.config),
        compacted_tool_messages: compacted_count
      }

      {prepared_messages, %{updated_state | prompt_context: prompt_context}}
    else
      {messages, state}
    end
  end

  def prepare_tool_result(entry, result, %{} = state) do
    if enabled?(state) and get_in(state, [:config, :tool_results, :enabled]) do
      maybe_spill_tool_result(entry, result, state)
    else
      {result, state}
    end
  end

  def finalize_result({:ok, content}, %{} = state) do
    maybe_attach_metadata({:ok, content}, state)
  end

  def finalize_result({:ok, content, meta}, %{} = state) when is_map(meta) do
    maybe_attach_metadata({:ok, content, meta}, state)
  end

  def finalize_result(other, _state), do: other

  defp maybe_attach_metadata({:ok, content}, %{config: %{return_metadata: true}} = state) do
    metadata = build_metadata(state)

    if metadata == %{} do
      {:ok, content}
    else
      {:ok, content, %{context_hygiene: metadata}}
    end
  end

  defp maybe_attach_metadata({:ok, content, meta}, %{config: %{return_metadata: true}} = state) do
    metadata = build_metadata(state)

    if metadata == %{} do
      {:ok, content, meta}
    else
      {:ok, content, Map.put(meta, :context_hygiene, metadata)}
    end
  end

  defp maybe_attach_metadata(result, _state), do: result

  defp build_metadata(%{spills: spills, prompt_context: prompt_context}) do
    %{}
    |> maybe_put(:prompt_context, prompt_context)
    |> maybe_put(:spilled_tool_results, Enum.reverse(spills), spills != [])
  end

  defp compact_messages(messages, %{} = state) do
    keep_recent = get_in(state, [:config, :tool_results, :keep_recent]) || 0

    protected_tool_indexes =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {message, _index} -> tool_message?(message) end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.reverse()
      |> Enum.take(keep_recent)
      |> MapSet.new()

    messages
    |> Enum.with_index()
    |> Enum.map_reduce({state, 0}, fn {message, index}, {current_state, compacted_count} ->
      cond do
        not tool_message?(message) ->
          {message, {current_state, compacted_count}}

        MapSet.member?(protected_tool_indexes, index) ->
          {message, {current_state, compacted_count}}

        not get_in(current_state, [:config, :tool_results, :compact_older]) ->
          {message, {current_state, compacted_count}}

        already_preview?(message) ->
          {message, {current_state, compacted_count}}

        compactable_tool_message?(message, current_state.config) ->
          {compacted_message, updated_state} =
            compact_tool_message(message, current_state, :history_compaction)

          {compacted_message, {updated_state, compacted_count + 1}}

        true ->
          {message, {current_state, compacted_count}}
      end
    end)
    |> then(fn {prepared_messages, {updated_state, compacted_count}} ->
      {prepared_messages, updated_state, compacted_count}
    end)
  end

  defp maybe_spill_tool_result(entry, result, %{} = state) do
    if get_in(state, [:config, :tool_results, :spill_oversized]) do
      encoded = encode_result(result)
      max_inline_chars = get_in(state, [:config, :tool_results, :max_inline_chars]) || 2_000

      if byte_size(encoded) > max_inline_chars do
        {preview_payload, updated_state} =
          spill_payload(result, encoded, state, %{
            reason: :oversized,
            tool: entry.source.remote_name,
            qualified_tool: entry.llm_name,
            server: entry.source.server,
            source: entry.source.type,
            bytes: byte_size(encoded)
          })

        {preview_payload, updated_state}
      else
        {result, state}
      end
    else
      {result, state}
    end
  end

  defp compact_tool_message(message, %{} = state, reason) do
    content = message_content(message)

    {preview_payload, updated_state} =
      spill_payload(content, content, state, %{
        reason: reason,
        tool: message_name(message),
        qualified_tool: message_name(message),
        server: nil,
        source: :tool_message,
        bytes: byte_size(content)
      })

    {put_message_content(message, Jason.encode!(preview_payload)), updated_state}
  end

  defp spill_payload(raw_result, encoded_result, %{} = state, metadata) do
    ttl_ms = get_in(state, [:config, :tool_results, :store_ttl_ms]) || 15 * 60 * 1000

    storage_metadata =
      metadata
      |> maybe_put(:run_id, state.run_id, not is_nil(state.run_id))
      |> maybe_put(:step_name, state.step_name, not is_nil(state.step_name))
      |> maybe_put(:tenant, state.tenant, not is_nil(state.tenant))

    handle = ToolResultStore.put(raw_result, storage_metadata, ttl_ms)

    preview_payload = %{
      kind: @preview_kind,
      handle: handle,
      tool: metadata.tool,
      qualified_tool: metadata.qualified_tool,
      server: metadata.server,
      source: metadata.source,
      reason: normalize_reason(metadata.reason),
      bytes: metadata.bytes,
      preview: preview_text(encoded_result, state.config),
      sensitive_types: sensitive_preview_types(encoded_result, state.config)
    }

    spill_record =
      preview_payload
      |> Map.take([
        :handle,
        :tool,
        :qualified_tool,
        :server,
        :source,
        :reason,
        :bytes,
        :sensitive_types
      ])

    {preview_payload, %{state | spills: [spill_record | state.spills]}}
  end

  defp count_static_messages(messages, config) do
    static_roles = MapSet.new(get_in(config, [:prompt, :static_roles]) || ["system", "developer"])

    Enum.count(messages, fn message ->
      message
      |> message_role()
      |> then(&MapSet.member?(static_roles, &1))
    end)
  end

  defp compactable_tool_message?(message, config) do
    preview_chars = get_in(config, [:tool_results, :preview_chars]) || 320
    byte_size(message_content(message)) > preview_chars
  end

  defp preview_text(encoded_result, config) do
    preview_chars = get_in(config, [:tool_results, :preview_chars]) || 320

    cond do
      get_in(config, [:tool_results, :summarize_sensitive_previews]) and
          sensitive_preview_types(encoded_result, config) != [] ->
        Redaction.summary(encoded_result,
          types: sensitive_preview_types(encoded_result, config),
          preview_chars: preview_chars
        )

      byte_size(encoded_result) <= preview_chars ->
        encoded_result

      true ->
        binary_part(encoded_result, 0, preview_chars) <> "... [truncated]"
    end
  end

  defp sensitive_preview_types(encoded_result, config) do
    types = get_in(config, [:tool_results, :sensitive_preview_types]) || []

    if types == [] do
      []
    else
      Redaction.detect(encoded_result, types: types)
    end
  end

  defp already_preview?(message) do
    String.contains?(message_content(message), ~s("kind":"#{@preview_kind}"))
  end

  defp encode_result(result) when is_binary(result), do: result
  defp encode_result(result), do: Jason.encode!(result)

  defp message_role(message) do
    message
    |> Map.get(:role)
    |> case do
      nil -> Map.get(message, "role")
      value -> value
    end
    |> to_string()
  end

  defp message_name(message) do
    Map.get(message, :name) || Map.get(message, "name") || "tool"
  end

  defp message_content(message) do
    Map.get(message, :content) || Map.get(message, "content") || ""
  end

  defp put_message_content(message, content) when is_map(message) do
    cond do
      Map.has_key?(message, :content) -> Map.put(message, :content, content)
      true -> Map.put(message, "content", content)
    end
  end

  defp tool_message?(message) do
    message_role(message) == "tool"
  end

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:context_hygiene)
      |> normalize_config()

    merge_config(global, per_call)
  end

  defp normalize_config(nil), do: %{}
  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}

  defp normalize_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "context hygiene config must be a keyword list, map, boolean, or nil, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      return_metadata: normalize_booleanish(fetch_value(config, :return_metadata)),
      prompt: normalize_prompt_config(fetch_value(config, :prompt)),
      tool_results: normalize_tool_results_config(fetch_value(config, :tool_results))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "context hygiene config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(
      :prompt,
      @default_config.prompt
      |> Map.merge(Map.get(global, :prompt, %{}))
      |> Map.merge(Map.get(per_call, :prompt, %{}))
    )
    |> Map.put(
      :tool_results,
      @default_config.tool_results
      |> Map.merge(Map.get(global, :tool_results, %{}))
      |> Map.merge(Map.get(per_call, :tool_results, %{}))
    )
  end

  defp normalize_prompt_config(nil), do: nil

  defp normalize_prompt_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError, "context hygiene prompt config must be a keyword list or map"
    end

    config
    |> Enum.into(%{})
    |> normalize_prompt_config()
  end

  defp normalize_prompt_config(%{} = config) do
    %{
      static_roles: normalize_roles(fetch_value(config, :static_roles))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_prompt_config(_other), do: nil

  defp normalize_tool_results_config(nil), do: nil

  defp normalize_tool_results_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError, "context hygiene tool_results config must be a keyword list or map"
    end

    config
    |> Enum.into(%{})
    |> normalize_tool_results_config()
  end

  defp normalize_tool_results_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      spill_oversized: normalize_booleanish(fetch_value(config, :spill_oversized)),
      compact_older: normalize_booleanish(fetch_value(config, :compact_older)),
      keep_recent: normalize_positive_integer(fetch_value(config, :keep_recent)),
      max_inline_chars: normalize_positive_integer(fetch_value(config, :max_inline_chars)),
      preview_chars: normalize_positive_integer(fetch_value(config, :preview_chars)),
      store_ttl_ms: normalize_positive_integer(fetch_value(config, :store_ttl_ms)),
      summarize_sensitive_previews:
        normalize_booleanish(fetch_value(config, :summarize_sensitive_previews)),
      sensitive_preview_types:
        normalize_sensitive_preview_types(fetch_value(config, :sensitive_preview_types))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_tool_results_config(_other), do: nil

  defp normalize_roles(nil), do: nil
  defp normalize_roles(roles) when is_list(roles), do: Enum.map(roles, &to_string/1)
  defp normalize_roles(role), do: [to_string(role)]

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil

  defp normalize_sensitive_preview_types(nil), do: nil

  defp normalize_sensitive_preview_types(types) when is_list(types) do
    types
    |> Enum.flat_map(&normalize_sensitive_preview_types/1)
    |> Enum.uniq()
  end

  defp normalize_sensitive_preview_types(type)
       when type in [:email, :phone, :ssn, :payment_card, :auth_token],
       do: [type]

  defp normalize_sensitive_preview_types(type) when is_binary(type) do
    case String.downcase(type) do
      "email" -> [:email]
      "phone" -> [:phone]
      "ssn" -> [:ssn]
      "payment_card" -> [:payment_card]
      "auth_token" -> [:auth_token]
      _ -> []
    end
  end

  defp normalize_sensitive_preview_types(_type), do: []

  defp normalize_booleanish(nil), do: nil
  defp normalize_booleanish(value) when value in [true, false], do: value
  defp normalize_booleanish("true"), do: true
  defp normalize_booleanish("false"), do: false
  defp normalize_booleanish(_value), do: nil

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value, false), do: map

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get_from_context(key) do
    case Process.get({:synaptic_context, key}) do
      nil -> nil
      value -> value
    end
  end
end
