defmodule Synaptic.ActionControls do
  @moduledoc false

  @table :synaptic_action_controls
  @risk_order %{low: 0, medium: 1, high: 2, critical: 3}

  @default_config %{
    enabled: false,
    return_metadata: false,
    emit_telemetry: true,
    rate_limits: [],
    blast_radius: [],
    idempotency: %{
      enabled: false,
      fields: ["idempotency_key", "idempotencykey", "request_id", "requestid"],
      require_for: %{
        destructive: false,
        risk_at_or_above: nil,
        tools: []
      },
      duplicate_behavior: :deny
    },
    retries: %{
      enabled: false,
      max_attempts: 1,
      backoff_ms: 0,
      retry_codes: ["tool_call_failed"],
      sources: [:mcp]
    }
  }

  @type state :: %{
          config: map(),
          events: [map()]
        }

  def new(opts \\ []) when is_list(opts) do
    %{
      config: resolve_config(opts),
      events: []
    }
  end

  def enabled?(%{config: %{enabled: true}}), do: true
  def enabled?(_state), do: false

  def dispatch(entry, args, opts, %{} = state, fun)
      when is_map(entry) and is_map(args) and is_function(fun, 0) do
    request = build_request(entry, args, opts)

    if enabled?(state) do
      ensure_table!()

      with_idempotency_lock(request, state.config, fn ->
        dispatch_enabled(entry, request, state, fun)
      end)
    else
      {fun.(), state}
    end
  end

  defp dispatch_enabled(entry, request, state, fun) do
    case preflight(request, state.config) do
      {:allow, request} ->
        {result, attempts} = execute_with_retries(fun, request, state.config)
        record_invocation(request, result, attempts)
        maybe_emit(:allow, request, result, attempts, state.config)
        {result, record_event(state, action_trace(:allow, request, result, attempts))}

      {:deny, reason} ->
        result = denied_payload(entry, reason)
        maybe_emit(:deny, request, result, 0, state.config)
        {result, record_event(state, action_trace(:deny, request, result, 0))}

      {:cached, cached_result, reason} ->
        maybe_emit(:cached, request, cached_result, 0, state.config)

        {cached_result,
         record_event(
           state,
           action_trace(:cached, Map.put(request, :reason, reason), cached_result, 0)
         )}
    end
  end

  defp with_idempotency_lock(request, config, fun) do
    idempotency = Map.get(config, :idempotency, %{})

    if Map.get(idempotency, :enabled, false) and not is_nil(request.idempotency_key) do
      lock =
        {request.tenant, request.run_id || "global", request.qualified_tool,
         request.idempotency_key}

      :global.trans({{__MODULE__, lock}, self()}, fun)
    else
      fun.()
    end
  end

  def finalize_result({:ok, content}, %{config: %{return_metadata: true}} = state) do
    events = Enum.reverse(state.events)

    if events == [] do
      {:ok, content}
    else
      {:ok, content, %{action_controls: %{events: events}}}
    end
  end

  def finalize_result({:ok, content, meta}, %{config: %{return_metadata: true}} = state)
      when is_map(meta) do
    events = Enum.reverse(state.events)

    if events == [] do
      {:ok, content, meta}
    else
      {:ok, content, Map.put(meta, :action_controls, %{events: events})}
    end
  end

  def finalize_result(other, _state), do: other

  def prune_expired do
    ensure_table!()
    now = System.system_time(:millisecond)

    :ets.foldl(
      fn {key, entry}, acc ->
        if Map.get(entry, :expires_at, now) < now do
          :ets.delete_object(@table, {key, entry})
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end

  defp preflight(request, config) do
    with :ok <- check_rate_limits(request, config),
         :ok <- check_blast_radius(request, config),
         {:ok, request} <- check_idempotency(request, config) do
      {:allow, request}
    else
      {:cached, result, reason} -> {:cached, result, reason}
      {:deny, reason} -> {:deny, reason}
    end
  end

  defp execute_with_retries(fun, request, config) do
    retries = Map.get(config, :retries, %{})

    if retry_enabled?(request, retries) do
      max_attempts = max(Map.get(retries, :max_attempts, 1), 1)
      backoff_ms = Map.get(retries, :backoff_ms, 0)
      retry_codes = Map.get(retries, :retry_codes, [])

      Enum.reduce_while(1..max_attempts, {nil, 0}, fn attempt, _acc ->
        result = fun.()

        cond do
          retryable_result?(result, retry_codes) and attempt < max_attempts ->
            if backoff_ms > 0, do: Process.sleep(backoff_ms)
            {:cont, {result, attempt}}

          true ->
            {:halt, {result, attempt}}
        end
      end)
    else
      {fun.(), 1}
    end
  end

  defp retry_enabled?(request, retries) do
    Map.get(retries, :enabled, false) and
      source_allowed?(request.source, Map.get(retries, :sources, []))
  end

  defp retryable_result?({:error, reason}, retry_codes), do: normalize_code(reason) in retry_codes

  defp retryable_result?(%{error: true} = result, retry_codes) do
    normalize_code(Map.get(result, :code) || Map.get(result, "code")) in retry_codes
  end

  defp retryable_result?(_result, _retry_codes), do: false

  defp check_rate_limits(request, config) do
    rules = Map.get(config, :rate_limits, [])

    rules
    |> Enum.find(fn rule ->
      matches_rule?(request, rule) and
        recent_count(request, rule.window_ms) >= rule.max_calls
    end)
    |> case do
      nil -> :ok
      rule -> {:deny, "rate_limit_exceeded:#{rule_label(rule)}"}
    end
  end

  defp check_blast_radius(request, config) do
    rules = Map.get(config, :blast_radius, [])

    rules
    |> Enum.find(fn rule ->
      matches_rule?(request, rule) and run_count(request) >= rule.max_calls
    end)
    |> case do
      nil -> :ok
      rule -> {:deny, "blast_radius_exceeded:#{rule_label(rule)}"}
    end
  end

  defp check_idempotency(request, config) do
    idempotency = Map.get(config, :idempotency, %{})

    cond do
      not Map.get(idempotency, :enabled, false) ->
        {:ok, request}

      idempotency_required?(request, idempotency) and is_nil(request.idempotency_key) ->
        {:deny, "idempotency_key_required"}

      is_nil(request.idempotency_key) ->
        {:ok, request}

      true ->
        case existing_idempotent_result(request) do
          nil ->
            {:ok, request}

          cached_result ->
            case Map.get(idempotency, :duplicate_behavior, :deny) do
              :return_cached -> {:cached, cached_result, "duplicate_idempotency_key"}
              _ -> {:deny, "duplicate_idempotency_key"}
            end
        end
    end
  end

  defp idempotency_required?(request, idempotency) do
    require_for = Map.get(idempotency, :require_for, %{})
    tools = Map.get(require_for, :tools, [])
    risk_threshold = Map.get(require_for, :risk_at_or_above)

    (Map.get(require_for, :destructive, false) and request.metadata.destructive) or
      (risk_threshold && risk_at_or_above?(request.metadata.risk, risk_threshold)) or
      request.qualified_tool in Enum.map(List.wrap(tools), &to_string/1)
  end

  defp existing_idempotent_result(request) do
    invocation_entries()
    |> Enum.find(fn entry ->
      entry.run_id == request.run_id and
        entry.qualified_tool == request.qualified_tool and
        entry.idempotency_key == request.idempotency_key and
        entry.status == :allow
    end)
    |> case do
      nil -> nil
      entry -> entry.result
    end
  end

  defp recent_count(request, window_ms) do
    threshold = System.system_time(:millisecond) - window_ms

    invocation_entries()
    |> Enum.count(fn entry ->
      entry.inserted_at >= threshold and
        entry.tool == request.tool and
        entry.source == request.source and
        entry.server == request.server and
        same_tenant?(entry.tenant, request.tenant)
    end)
  end

  defp run_count(request) do
    invocation_entries()
    |> Enum.count(fn entry ->
      entry.run_id == request.run_id and
        entry.tool == request.tool and
        entry.source == request.source and
        entry.server == request.server and
        same_tenant?(entry.tenant, request.tenant)
    end)
  end

  defp record_invocation(request, result, attempts) do
    now = System.system_time(:millisecond)

    entry = %{
      run_id: request.run_id,
      tenant: request.tenant,
      tool: request.tool,
      qualified_tool: request.qualified_tool,
      source: request.source,
      server: request.server,
      idempotency_key: request.idempotency_key,
      status: :allow,
      attempts: attempts,
      result: result,
      inserted_at: now,
      expires_at: now + max_window_ms()
    }

    :ets.insert(
      @table,
      {{request.run_id || "global", request.qualified_tool, now, make_ref()}, entry}
    )
  end

  defp invocation_entries do
    ensure_table!()

    now = System.system_time(:millisecond)

    :ets.foldl(
      fn {key, entry}, acc ->
        if Map.get(entry, :expires_at, now) < now do
          :ets.delete_object(@table, {key, entry})
          acc
        else
          [entry | acc]
        end
      end,
      [],
      @table
    )
  end

  defp action_trace(status, request, result, attempts) do
    %{
      status: status,
      tool: request.tool,
      qualified_tool: request.qualified_tool,
      source: request.source,
      server: request.server,
      tenant: request.tenant,
      idempotency_key_present: not is_nil(request.idempotency_key),
      attempts: attempts,
      result_code: normalize_result_code(result),
      reason: Map.get(request, :reason)
    }
  end

  defp denied_payload(entry, reason) do
    %{
      error: true,
      source: entry.source.type,
      code: denial_code(reason),
      message: "Tool dispatch was blocked by action controls.",
      reason: reason,
      server: entry.source.server,
      tool: entry.source.remote_name
    }
  end

  defp denial_code(reason) when is_binary(reason) do
    cond do
      String.starts_with?(reason, "rate_limit_exceeded") -> "rate_limit_exceeded"
      String.starts_with?(reason, "blast_radius_exceeded") -> "blast_radius_exceeded"
      true -> "action_blocked"
    end
  end

  defp maybe_emit(status, request, result, attempts, %{emit_telemetry: true}) do
    :telemetry.execute(
      [:synaptic, :action_controls, :dispatch],
      %{count: 1, attempts: attempts},
      %{
        status: status,
        tool: request.tool,
        qualified_tool: request.qualified_tool,
        source: request.source,
        server: request.server,
        tenant: request.tenant,
        result_code: normalize_result_code(result)
      }
    )
  end

  defp maybe_emit(_status, _request, _result, _attempts, _config), do: :ok

  defp record_event(state, trace) do
    Map.update!(state, :events, &[trace | &1])
  end

  defp build_request(entry, args, opts) do
    metadata = Map.get(entry, :metadata, %{})
    idempotency = extract_idempotency_key(args, opts)

    %{
      tool: get_in(entry, [:source, :remote_name]) || Map.get(entry, :llm_name),
      qualified_tool: Map.get(entry, :llm_name),
      source: get_in(entry, [:source, :type]) || :local,
      server: get_in(entry, [:source, :server]),
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      tenant: Keyword.get(opts, :tenant) || get_from_context(:__tenant__),
      metadata: metadata,
      args: args,
      idempotency_key: idempotency
    }
  end

  defp extract_idempotency_key(args, opts) do
    fields =
      opts
      |> Keyword.get(:action_controls)
      |> normalize_config()
      |> Map.get(:idempotency, %{})
      |> Map.get(:fields, @default_config.idempotency.fields)

    Enum.find_value(fields, fn field ->
      normalized_field = to_string(field)

      Enum.find_value(args, fn {key, value} ->
        if to_string(key) == normalized_field, do: value
      end)
    end)
  end

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:action_controls)
      |> normalize_config()

    merge_config(global, per_call)
  end

  defp normalize_config(nil), do: %{}
  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}

  defp normalize_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "action controls config must be a keyword list, map, boolean, or nil, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      return_metadata: normalize_booleanish(fetch_value(config, :return_metadata)),
      emit_telemetry: normalize_booleanish(fetch_value(config, :emit_telemetry)),
      rate_limits: normalize_rules(fetch_value(config, :rate_limits)),
      blast_radius: normalize_rules(fetch_value(config, :blast_radius)),
      idempotency: normalize_idempotency(fetch_value(config, :idempotency)),
      retries: normalize_retries(fetch_value(config, :retries))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "action controls config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(:rate_limits, Map.get(per_call, :rate_limits, Map.get(global, :rate_limits, [])))
    |> Map.put(
      :blast_radius,
      Map.get(per_call, :blast_radius, Map.get(global, :blast_radius, []))
    )
    |> Map.put(
      :idempotency,
      @default_config.idempotency
      |> Map.merge(Map.get(global, :idempotency, %{}))
      |> Map.merge(Map.get(per_call, :idempotency, %{}))
    )
    |> Map.put(
      :retries,
      @default_config.retries
      |> Map.merge(Map.get(global, :retries, %{}))
      |> Map.merge(Map.get(per_call, :retries, %{}))
    )
  end

  defp normalize_rules(nil), do: []
  defp normalize_rules(rules) when is_list(rules), do: Enum.map(rules, &normalize_rule/1)
  defp normalize_rules(_other), do: []

  defp normalize_rule(rule) when is_list(rule) do
    rule
    |> Enum.into(%{})
    |> normalize_rule()
  end

  defp normalize_rule(%{} = rule) do
    %{
      tool: normalize_string(fetch_value(rule, :tool)),
      tools: normalize_string_list(fetch_value(rule, :tools)),
      source: normalize_source(fetch_value(rule, :source)),
      server: normalize_string(fetch_value(rule, :server)),
      max_calls: normalize_positive_integer(fetch_value(rule, :max_calls)) || 1,
      window_ms: normalize_positive_integer(fetch_value(rule, :window_ms)) || 60_000,
      label: normalize_string(fetch_value(rule, :label))
    }
  end

  defp normalize_rule(_other), do: %{}

  defp normalize_idempotency(nil), do: nil

  defp normalize_idempotency(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_idempotency()
  end

  defp normalize_idempotency(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      fields: normalize_string_list(fetch_value(config, :fields)),
      require_for: normalize_require_for(fetch_value(config, :require_for)),
      duplicate_behavior: normalize_duplicate_behavior(fetch_value(config, :duplicate_behavior))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_idempotency(_other), do: nil

  defp normalize_require_for(nil), do: nil

  defp normalize_require_for(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_require_for()
  end

  defp normalize_require_for(%{} = config) do
    %{
      destructive: normalize_booleanish(fetch_value(config, :destructive)),
      risk_at_or_above: normalize_risk(fetch_value(config, :risk_at_or_above)),
      tools: normalize_string_list(fetch_value(config, :tools))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_require_for(_other), do: nil

  defp normalize_retries(nil), do: nil

  defp normalize_retries(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_retries()
  end

  defp normalize_retries(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      max_attempts: normalize_positive_integer(fetch_value(config, :max_attempts)),
      backoff_ms: normalize_non_negative_integer(fetch_value(config, :backoff_ms)),
      retry_codes: normalize_string_list(fetch_value(config, :retry_codes)),
      sources: normalize_sources(fetch_value(config, :sources))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_retries(_other), do: nil

  defp normalize_duplicate_behavior(value) when value in [:deny, :return_cached], do: value

  defp normalize_duplicate_behavior(value) when is_binary(value) do
    case String.downcase(value) do
      "deny" -> :deny
      "return_cached" -> :return_cached
      _ -> nil
    end
  end

  defp normalize_duplicate_behavior(_value), do: nil

  defp normalize_sources(nil), do: nil
  defp normalize_sources(values) when is_list(values), do: Enum.map(values, &normalize_source/1)
  defp normalize_sources(value), do: [normalize_source(value)]

  defp normalize_source(value) when value in [:local, :mcp], do: value
  defp normalize_source("local"), do: :local
  defp normalize_source("mcp"), do: :mcp
  defp normalize_source(_value), do: nil

  defp matches_rule?(request, rule) do
    matches_tool_rule?(request, rule) and
      matches_server_rule?(request, rule) and
      matches_source_rule?(request, rule)
  end

  defp matches_tool_rule?(_request, %{tool: nil, tools: nil}), do: true

  defp matches_tool_rule?(request, %{tool: tool}) when is_binary(tool),
    do: request.qualified_tool == tool

  defp matches_tool_rule?(request, %{tools: tools}) when is_list(tools),
    do: request.qualified_tool in tools

  defp matches_tool_rule?(_request, _rule), do: true

  defp matches_server_rule?(_request, %{server: nil}), do: true
  defp matches_server_rule?(request, %{server: server}), do: request.server == server

  defp matches_source_rule?(_request, %{source: nil}), do: true
  defp matches_source_rule?(request, %{source: source}), do: request.source == source

  defp source_allowed?(source, allowed_sources) do
    allowed_sources = Enum.reject(List.wrap(allowed_sources), &is_nil/1)
    allowed_sources == [] or source in allowed_sources
  end

  defp same_tenant?(left, right), do: left == right

  defp normalize_result_code({:error, reason}), do: normalize_code(reason)

  defp normalize_result_code(%{} = result) do
    normalize_code(Map.get(result, :code) || Map.get(result, "code") || :ok)
  end

  defp normalize_result_code(_result), do: "ok"

  defp normalize_code(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_code(value) when is_binary(value), do: value
  defp normalize_code(value), do: inspect(value)

  defp risk_at_or_above?(risk, threshold) do
    Map.get(@risk_order, risk, -1) >= Map.get(@risk_order, threshold, 10)
  end

  defp max_window_ms do
    windows =
      @default_config.rate_limits
      |> Kernel.++(@default_config.blast_radius)
      |> Enum.map(&Map.get(&1, :window_ms, 60_000))

    Enum.max([60_000 | windows])
  end

  defp rule_label(%{label: label}) when is_binary(label) and byte_size(label) > 0, do: label
  defp rule_label(rule), do: rule.tool || rule.server || "rule"

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :bag,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp normalize_booleanish(nil), do: nil
  defp normalize_booleanish(value) when value in [true, false], do: value
  defp normalize_booleanish("true"), do: true
  defp normalize_booleanish("false"), do: false
  defp normalize_booleanish(_value), do: nil

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_non_negative_integer(_value), do: nil

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

  defp normalize_string_list(nil), do: nil
  defp normalize_string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_string_list(value), do: [to_string(value)]

  defp normalize_risk(value) when value in [:low, :medium, :high, :critical], do: value

  defp normalize_risk(value) when is_binary(value) do
    case String.downcase(value) do
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "critical" -> :critical
      _ -> nil
    end
  end

  defp normalize_risk(_value), do: nil

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
