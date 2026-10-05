defmodule Synaptic.ToolPolicy do
  @moduledoc false

  @decisions [:allow, :ask, :deny]
  @risk_order %{low: 0, medium: 1, high: 2, critical: 3}

  @default_config %{
    enabled: false,
    default_decision: :allow,
    rules: [],
    require_approval: %{
      tools_marked: true,
      destructive: false,
      risk_at_or_above: nil
    },
    approval_resolver: nil,
    resolver_failure: :ask,
    return_decisions: false,
    emit_telemetry: true
  }

  @type decision :: :allow | :ask | :deny

  @type state :: %{
          config: map(),
          decisions: [map()]
        }

  def new(opts \\ []) when is_list(opts) do
    %{
      config: resolve_config(opts),
      decisions: []
    }
  end

  def enabled?(%{config: %{enabled: true}}), do: true
  def enabled?(_state), do: false

  def authorize(entry, args, opts, %{} = state) when is_map(entry) and is_map(args) do
    request = build_request(entry, args, opts)

    if enabled?(state) do
      evaluate_enabled(request, state)
    else
      trace =
        request
        |> base_trace(state.config)
        |> Map.put(:decision, :allow)
        |> Map.put(:reason, "policy_disabled")
        |> Map.put(:matches, [])
        |> Map.put(:approval, nil)

      {trace.decision, public_trace(trace), record_decision(state, trace)}
    end
  end

  def authorize(_entry, _args, _opts, %{} = state) do
    trace = %{
      decision: :deny,
      reason: "invalid_tool_request",
      matches: [],
      approval: nil
    }

    {:deny, trace, record_decision(state, trace)}
  end

  def finalize_result({:ok, content}, %{} = state) do
    maybe_attach_decisions({:ok, content}, state)
  end

  def finalize_result({:ok, content, meta}, %{} = state) when is_map(meta) do
    maybe_attach_decisions({:ok, content, meta}, state)
  end

  def finalize_result(other, _state), do: other

  def default_metadata(:local, metadata) when is_map(metadata) do
    normalize_metadata(metadata)
  end

  def default_metadata(:mcp_tool, metadata) when is_map(metadata) do
    metadata
    |> Map.merge(%{
      read_only: false,
      destructive: false,
      concurrency_safe: true,
      needs_approval: false,
      data_class: :general,
      risk: :medium,
      max_result_size: nil
    })
    |> normalize_metadata()
  end

  def default_metadata(:mcp_resource, metadata) when is_map(metadata) do
    metadata
    |> Map.merge(%{
      read_only: true,
      destructive: false,
      concurrency_safe: true,
      needs_approval: false,
      data_class: :general,
      risk: :low,
      max_result_size: nil
    })
    |> normalize_metadata()
  end

  defp maybe_attach_decisions({:ok, content}, %{
         config: %{return_decisions: true},
         decisions: decisions
       })
       when decisions != [] do
    {:ok, content, %{policy_decisions: Enum.reverse(decisions)}}
  end

  defp maybe_attach_decisions(
         {:ok, content, meta},
         %{config: %{return_decisions: true}, decisions: decisions}
       )
       when is_map(meta) and decisions != [] do
    {:ok, content, Map.put(meta, :policy_decisions, Enum.reverse(decisions))}
  end

  defp maybe_attach_decisions(result, _state), do: result

  defp evaluate_enabled(request, %{} = state) do
    config = state.config

    matches =
      request
      |> builtin_matches(config)
      |> Kernel.++(rule_matches(request, config.rules))

    initial =
      choose_decision(matches, config.default_decision)
      |> finalize_trace(request, config, matches)

    trace =
      case initial.decision do
        :ask -> maybe_resolve_approval(initial, request, config)
        _ -> initial
      end

    maybe_emit(trace, config)
    {trace.decision, public_trace(trace), record_decision(state, trace)}
  end

  defp build_request(entry, args, opts) do
    metadata = normalize_metadata(Map.get(entry, :metadata, %{}))

    %{
      qualified_tool: Map.get(entry, :llm_name),
      tool: get_in(entry, [:source, :remote_name]) || Map.get(entry, :llm_name),
      source: get_in(entry, [:source, :type]) || :local,
      server: get_in(entry, [:source, :server]),
      step: Keyword.get(opts, :step_name) || get_from_context(:__step_name__),
      agent: Keyword.get(opts, :__tool_policy_agent__),
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      metadata: metadata,
      args: args
    }
  end

  defp base_trace(request, config) do
    %{
      tool: request.tool,
      qualified_tool: request.qualified_tool,
      source: request.source,
      server: request.server,
      step: request.step,
      agent: request.agent,
      run_id: request.run_id,
      metadata: request.metadata,
      default_decision: config.default_decision
    }
  end

  defp finalize_trace({decision, reason, winning_match}, request, config, matches) do
    request
    |> base_trace(config)
    |> Map.put(:decision, decision)
    |> Map.put(:reason, reason)
    |> Map.put(:matches, Enum.map(matches, &public_match/1))
    |> Map.put(:winning_match, public_match(winning_match))
    |> Map.put(:approval, nil)
  end

  defp choose_decision([], default_decision), do: {default_decision, "default_decision", nil}

  defp choose_decision(matches, default_decision) do
    {default_decision, "default_decision", nil}
    |> then(fn default ->
      Enum.reduce(matches, default, fn match, current ->
        if decision_rank(match.decision) > decision_rank(elem(current, 0)) do
          {match.decision, match.reason, match}
        else
          current
        end
      end)
    end)
  end

  defp builtin_matches(request, config) do
    approval_config = Map.get(config, :require_approval, %{})
    metadata = request.metadata
    risk_threshold = Map.get(approval_config, :risk_at_or_above)

    []
    |> maybe_add_match(
      Map.get(approval_config, :tools_marked, true) and metadata.needs_approval,
      %{
        decision: :ask,
        reason: "tool_marked_requires_approval",
        kind: :metadata,
        match: %{needs_approval: true}
      }
    )
    |> maybe_add_match(
      Map.get(approval_config, :destructive, false) and metadata.destructive,
      %{
        decision: :ask,
        reason: "destructive_tool_requires_approval",
        kind: :metadata,
        match: %{destructive: true}
      }
    )
    |> maybe_add_match(
      not is_nil(risk_threshold) and risk_at_or_above?(metadata.risk, risk_threshold),
      %{
        decision: :ask,
        reason: "risk_threshold_requires_approval",
        kind: :metadata,
        match: %{risk_at_or_above: normalize_risk(risk_threshold)}
      }
    )
  end

  defp maybe_add_match(matches, true, match), do: matches ++ [match]
  defp maybe_add_match(matches, _predicate, _match), do: matches

  defp rule_matches(request, rules) when is_list(rules) do
    rules
    |> Enum.with_index()
    |> Enum.flat_map(fn {rule, index} ->
      normalized_rule = normalize_rule(rule)

      if rule_matches_request?(request, normalized_rule) do
        [
          %{
            decision: normalized_rule.decision,
            reason: normalized_rule.reason || "rule_#{index}",
            kind: :rule,
            rule_index: index,
            match: rule_match_summary(normalized_rule)
          }
        ]
      else
        []
      end
    end)
  end

  defp rule_matches(_request, _rules), do: []

  defp maybe_resolve_approval(trace, request, config) do
    case normalize_resolver_result(run_approval_resolver(request, trace, config)) do
      {:allow, reason} ->
        trace
        |> Map.put(:decision, :allow)
        |> Map.put(:reason, reason)
        |> Map.put(:approval, %{decision: :allow, reason: reason})

      {:deny, reason} ->
        trace
        |> Map.put(:decision, :deny)
        |> Map.put(:reason, reason)
        |> Map.put(:approval, %{decision: :deny, reason: reason})

      {:ask, reason} ->
        trace
        |> Map.put(:reason, reason)
        |> Map.put(:approval, %{decision: :ask, reason: reason})
    end
  end

  defp run_approval_resolver(_request, _trace, %{approval_resolver: nil}), do: :ask

  defp run_approval_resolver(request, trace, config) do
    resolver_request = %{
      tool: request.tool,
      qualified_tool: request.qualified_tool,
      source: request.source,
      server: request.server,
      step: request.step,
      agent: request.agent,
      run_id: request.run_id,
      metadata: request.metadata,
      args: request.args,
      trace: public_trace(trace)
    }

    try do
      case config.approval_resolver do
        resolver when is_function(resolver, 1) ->
          resolver.(resolver_request)

        {mod, fun, extra_args} when is_atom(mod) and is_atom(fun) and is_list(extra_args) ->
          apply(mod, fun, [resolver_request | extra_args])

        _ ->
          :ask
      end
    rescue
      _ ->
        Map.get(config, :resolver_failure, :ask)
    catch
      _, _ ->
        Map.get(config, :resolver_failure, :ask)
    end
  end

  defp normalize_resolver_result(:allow), do: {:allow, "approved_by_resolver"}
  defp normalize_resolver_result(:approve), do: {:allow, "approved_by_resolver"}
  defp normalize_resolver_result({:allow, reason}), do: {:allow, to_string(reason)}
  defp normalize_resolver_result({:approve, reason}), do: {:allow, to_string(reason)}
  defp normalize_resolver_result(:deny), do: {:deny, "denied_by_resolver"}
  defp normalize_resolver_result({:deny, reason}), do: {:deny, to_string(reason)}
  defp normalize_resolver_result(:ask), do: {:ask, "approval_required"}
  defp normalize_resolver_result({:ask, reason}), do: {:ask, to_string(reason)}
  defp normalize_resolver_result(true), do: {:allow, "approved_by_resolver"}
  defp normalize_resolver_result(false), do: {:deny, "denied_by_resolver"}

  defp normalize_resolver_result(other) when other in [:allow, :deny, :ask],
    do: {other, Atom.to_string(other)}

  defp normalize_resolver_result(_other), do: {:ask, "approval_required"}

  defp public_trace(trace) when is_map(trace) do
    trace
    |> Map.put(:metadata, trace[:metadata] || %{})
    |> Map.drop([:run_id])
  end

  defp public_match(nil), do: nil

  defp public_match(match) when is_map(match) do
    match
    |> Map.take([:decision, :reason, :kind, :rule_index, :match])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp rule_match_summary(rule) do
    rule
    |> Map.take([
      :tool,
      :tools,
      :server,
      :servers,
      :source,
      :step,
      :agent,
      :destructive,
      :read_only,
      :needs_approval,
      :risk,
      :risk_at_or_above,
      :data_class
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp record_decision(state, trace) do
    Map.update!(state, :decisions, &[public_trace(trace) | &1])
  end

  defp maybe_emit(trace, %{emit_telemetry: true}) do
    metadata = %{
      decision: trace.decision,
      reason: trace.reason,
      tool: trace.tool,
      qualified_tool: trace.qualified_tool,
      source: trace.source,
      server: trace.server,
      step: trace.step,
      agent: trace.agent,
      risk: trace.metadata.risk,
      read_only: trace.metadata.read_only,
      destructive: trace.metadata.destructive,
      needs_approval: trace.metadata.needs_approval,
      data_class: trace.metadata.data_class
    }

    :telemetry.execute([:synaptic, :tool, :policy], %{count: 1}, metadata)
  end

  defp maybe_emit(_trace, _config), do: :ok

  defp resolve_config(opts) do
    global_config =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_policy_config()

    per_call =
      opts
      |> Keyword.get(:policy)
      |> normalize_policy_config()

    merge_config(global_config, per_call)
  end

  defp normalize_policy_config(nil), do: %{}
  defp normalize_policy_config(false), do: %{enabled: false}
  defp normalize_policy_config(true), do: %{enabled: true}

  defp normalize_policy_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError, "tool policy config must be a keyword list, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_policy_config()
  end

  defp normalize_policy_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      default_decision: normalize_decision(fetch_value(config, :default_decision)),
      rules: normalize_rules(fetch_value(config, :rules)),
      require_approval: normalize_require_approval(fetch_value(config, :require_approval)),
      approval_resolver: fetch_value(config, :approval_resolver),
      resolver_failure: normalize_decision(fetch_value(config, :resolver_failure), :ask),
      return_decisions: normalize_booleanish(fetch_value(config, :return_decisions)),
      emit_telemetry: normalize_booleanish(fetch_value(config, :emit_telemetry))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_policy_config(other) do
    raise ArgumentError,
          "tool policy config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    global_require_approval = Map.get(global, :require_approval, %{})
    per_call_require_approval = Map.get(per_call, :require_approval, %{})

    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(:rules, Map.get(per_call, :rules, Map.get(global, :rules, @default_config.rules)))
    |> Map.put(
      :require_approval,
      Map.merge(@default_config.require_approval, global_require_approval)
    )
    |> then(fn config ->
      Map.put(
        config,
        :require_approval,
        Map.merge(config.require_approval, per_call_require_approval)
      )
    end)
  end

  defp normalize_booleanish(nil), do: nil
  defp normalize_booleanish(value) when value in [true, false], do: value
  defp normalize_booleanish("true"), do: true
  defp normalize_booleanish("false"), do: false
  defp normalize_booleanish(_value), do: nil

  defp normalize_decision(value, fallback \\ nil)
  defp normalize_decision(nil, fallback), do: fallback
  defp normalize_decision(value, _fallback) when value in @decisions, do: value

  defp normalize_decision(value, fallback) when is_binary(value) do
    case String.downcase(value) do
      "allow" -> :allow
      "ask" -> :ask
      "deny" -> :deny
      _ -> fallback
    end
  end

  defp normalize_decision(_value, fallback), do: fallback

  defp normalize_rules(nil), do: nil
  defp normalize_rules(rules) when is_list(rules), do: Enum.map(rules, &normalize_rule/1)
  defp normalize_rules(_other), do: []

  defp normalize_rule(rule) when is_list(rule) do
    unless Keyword.keyword?(rule) do
      raise ArgumentError, "tool policy rule must be a keyword list or map, got: #{inspect(rule)}"
    end

    rule
    |> Enum.into(%{})
    |> normalize_rule()
  end

  defp normalize_rule(%{} = rule) do
    %{
      decision: normalize_decision(fetch_value(rule, :decision), :allow),
      reason: fetch_value(rule, :reason),
      tool: fetch_value(rule, :tool),
      tools: normalize_listish(fetch_value(rule, :tools)),
      server: fetch_value(rule, :server),
      servers: normalize_listish(fetch_value(rule, :servers)),
      source: normalize_source(fetch_value(rule, :source)),
      step: normalize_atom_or_string(fetch_value(rule, :step)),
      agent: normalize_atom_or_string(fetch_value(rule, :agent)),
      destructive: fetch_value(rule, :destructive),
      read_only: fetch_value(rule, :read_only),
      needs_approval: fetch_value(rule, :needs_approval),
      risk: normalize_risk(fetch_value(rule, :risk)),
      risk_at_or_above: normalize_risk(fetch_value(rule, :risk_at_or_above)),
      data_class: normalize_data_class_filter(fetch_value(rule, :data_class))
    }
  end

  defp normalize_rule(other) do
    raise ArgumentError, "tool policy rule must be a keyword list or map, got: #{inspect(other)}"
  end

  defp normalize_require_approval(nil), do: %{}

  defp normalize_require_approval(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "tool policy require_approval config must be a keyword list or map, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_require_approval()
  end

  defp normalize_require_approval(%{} = config) do
    %{
      tools_marked: normalize_booleanish(fetch_value(config, :tools_marked)),
      destructive: normalize_booleanish(fetch_value(config, :destructive)),
      risk_at_or_above: normalize_risk(fetch_value(config, :risk_at_or_above))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_require_approval(_other), do: %{}

  defp normalize_source(nil), do: nil
  defp normalize_source(value) when value in [:local, :mcp], do: value
  defp normalize_source("local"), do: :local
  defp normalize_source("mcp"), do: :mcp
  defp normalize_source(_value), do: nil

  defp normalize_atom_or_string(nil), do: nil
  defp normalize_atom_or_string(value) when is_atom(value), do: value
  defp normalize_atom_or_string(value) when is_binary(value), do: value
  defp normalize_atom_or_string(value), do: to_string(value)

  defp normalize_listish(nil), do: nil
  defp normalize_listish(:all), do: :all
  defp normalize_listish("all"), do: :all
  defp normalize_listish(value) when is_list(value), do: value
  defp normalize_listish(value), do: [value]

  defp normalize_metadata(metadata) do
    %{
      read_only: Map.get(metadata, :read_only, false),
      destructive: Map.get(metadata, :destructive, false),
      concurrency_safe: Map.get(metadata, :concurrency_safe, true),
      needs_approval: Map.get(metadata, :needs_approval, false),
      data_class: normalize_data_class(Map.get(metadata, :data_class, :general)),
      risk: normalize_risk(Map.get(metadata, :risk, :medium)),
      max_result_size: Map.get(metadata, :max_result_size)
    }
  end

  defp normalize_data_class(value) when is_list(value),
    do: Enum.map(value, &normalize_data_class/1)

  defp normalize_data_class(value) when is_atom(value), do: value
  defp normalize_data_class(value) when is_binary(value), do: value
  defp normalize_data_class(_value), do: :general

  defp normalize_data_class_filter(nil), do: nil
  defp normalize_data_class_filter(value), do: normalize_data_class(value)

  defp normalize_risk(nil), do: nil
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
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Atom.to_string(key))
    end
  end

  defp rule_matches_request?(request, rule) do
    Enum.all?(
      [
        matches_tool?(request, rule),
        matches_server?(request, rule),
        matches_source?(request, rule),
        matches_step?(request, rule),
        matches_agent?(request, rule),
        matches_bool?(request.metadata.destructive, rule.destructive),
        matches_bool?(request.metadata.read_only, rule.read_only),
        matches_bool?(request.metadata.needs_approval, rule.needs_approval),
        matches_risk?(request.metadata.risk, rule.risk, rule.risk_at_or_above),
        matches_data_class?(request.metadata.data_class, rule.data_class)
      ],
      & &1
    )
  end

  defp matches_tool?(_request, %{tool: nil, tools: nil}), do: true

  defp matches_tool?(request, %{tool: tool}) when not is_nil(tool),
    do: request.qualified_tool == to_string(tool)

  defp matches_tool?(request, %{tools: :all}), do: not is_nil(request.qualified_tool)

  defp matches_tool?(request, %{tools: tools}) when is_list(tools) do
    Enum.any?(tools, fn tool -> request.qualified_tool == to_string(tool) end)
  end

  defp matches_tool?(_request, _rule), do: true

  defp matches_server?(_request, %{server: nil, servers: nil}), do: true

  defp matches_server?(request, %{server: server}) when not is_nil(server),
    do: request.server == to_string(server)

  defp matches_server?(_request, %{servers: :all}), do: true

  defp matches_server?(request, %{servers: servers}) when is_list(servers) do
    Enum.any?(servers, fn server -> request.server == to_string(server) end)
  end

  defp matches_server?(_request, _rule), do: true

  defp matches_source?(_request, %{source: nil}), do: true
  defp matches_source?(request, %{source: source}), do: request.source == source

  defp matches_step?(_request, %{step: nil}), do: true
  defp matches_step?(request, %{step: step}) when is_atom(step), do: request.step == step

  defp matches_step?(request, %{step: step}) when is_binary(step) do
    case request.step do
      nil -> false
      value -> to_string(value) == step
    end
  end

  defp matches_agent?(_request, %{agent: nil}), do: true
  defp matches_agent?(request, %{agent: agent}) when is_atom(agent), do: request.agent == agent

  defp matches_agent?(request, %{agent: agent}) when is_binary(agent) do
    case request.agent do
      nil -> false
      value -> to_string(value) == agent
    end
  end

  defp matches_bool?(_value, nil), do: true
  defp matches_bool?(value, expected), do: value == expected

  defp matches_risk?(_risk, nil, nil), do: true
  defp matches_risk?(risk, expected, nil), do: risk == expected
  defp matches_risk?(risk, _expected, threshold), do: risk_at_or_above?(risk, threshold)

  defp risk_at_or_above?(risk, threshold) do
    Map.get(@risk_order, risk, -1) >= Map.get(@risk_order, threshold, 10)
  end

  defp matches_data_class?(_value, nil), do: true

  defp matches_data_class?(value, expected) when is_list(expected) do
    normalized_value = normalize_data_class(value)
    Enum.any?(expected, &(normalize_data_class(&1) == normalized_value))
  end

  defp matches_data_class?(value, expected),
    do: normalize_data_class(value) == normalize_data_class(expected)

  defp decision_rank(:allow), do: 0
  defp decision_rank(:ask), do: 1
  defp decision_rank(:deny), do: 2

  defp get_from_context(key) do
    case Process.get({:synaptic_context, key}) do
      nil -> nil
      value -> value
    end
  end
end
