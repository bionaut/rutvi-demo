defmodule Synaptic.SecurityPolicy do
  @moduledoc false

  @decisions [:allow, :ask, :deny]
  @risk_order %{pii: 0, restricted_pii: 1, secret: 2}

  @default_config %{
    enabled: false,
    emit_telemetry: true,
    tenant: %{
      required_surfaces: []
    },
    pii: %{
      model_export: %{
        enabled: false,
        sensitivity_at_or_above: :restricted_pii,
        allow_models: []
      },
      tool_access: %{
        enabled: false,
        sensitivity_at_or_above: :pii,
        allowed_tools: [],
        allowed_agents: [],
        allowed_data_classes: []
      }
    },
    rules: []
  }

  def config(opts \\ []) when is_list(opts) do
    resolve_config(opts)
  end

  def authorize_prompt(opts, privacy_state) do
    request = build_prompt_request(opts, privacy_state)
    authorize(:prompt, request, resolve_config(opts))
  end

  def authorize_tool(entry, opts, privacy_state) when is_map(entry) do
    request = build_tool_request(entry, opts, privacy_state)
    authorize(:tool, request, resolve_config(opts))
  end

  def enabled?(opts) when is_list(opts) do
    resolve_config(opts).enabled
  end

  defp authorize(_surface, _request, %{enabled: false}),
    do: {:allow, %{decision: :allow, reason: "security_policy_disabled"}}

  defp authorize(surface, request, config) do
    matches =
      builtin_matches(surface, request, config) ++
        rule_matches(surface, request, Map.get(config, :rules, []))

    trace = choose_trace(surface, request, matches)
    maybe_emit(trace, config)
    {trace.decision, trace}
  end

  defp build_prompt_request(opts, privacy_state) do
    %{
      surface: :prompt,
      model: Keyword.get(opts, :model) || "unknown",
      agent: Keyword.get(opts, :__tool_policy_agent__),
      tenant: Keyword.get(opts, :tenant) || get_from_context(:__tenant__),
      step: Keyword.get(opts, :step_name) || get_from_context(:__step_name__),
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      sensitivities: privacy_sensitivities(privacy_state),
      highest_sensitivity: highest_sensitivity(privacy_state),
      source_kinds: privacy_source_kinds(privacy_state)
    }
  end

  defp build_tool_request(entry, opts, privacy_state) do
    %{
      surface: :tool,
      tool: get_in(entry, [:source, :remote_name]) || Map.get(entry, :llm_name),
      qualified_tool: Map.get(entry, :llm_name),
      source: get_in(entry, [:source, :type]) || :local,
      server: get_in(entry, [:source, :server]),
      data_class: get_in(entry, [:metadata, :data_class]) || :general,
      agent: Keyword.get(opts, :__tool_policy_agent__),
      tenant: Keyword.get(opts, :tenant) || get_from_context(:__tenant__),
      step: Keyword.get(opts, :step_name) || get_from_context(:__step_name__),
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      sensitivities: privacy_sensitivities(privacy_state),
      highest_sensitivity: highest_sensitivity(privacy_state),
      source_kinds: privacy_source_kinds(privacy_state)
    }
  end

  defp builtin_matches(surface, request, config) do
    []
    |> maybe_add_match(tenant_required?(surface, config) and is_nil(request.tenant), %{
      decision: :deny,
      reason: "tenant_required"
    })
    |> maybe_add_match(
      surface == :prompt and model_export_blocked?(request, config),
      %{
        decision: :deny,
        reason: "restricted_pii_model_export_blocked"
      }
    )
    |> maybe_add_match(
      surface == :tool and tool_access_blocked?(request, config),
      %{
        decision: :deny,
        reason: "pii_tool_access_blocked"
      }
    )
  end

  defp model_export_blocked?(request, config) do
    export = get_in(config, [:pii, :model_export]) || %{}

    Map.get(export, :enabled, false) and
      sensitivity_at_or_above?(
        request.highest_sensitivity,
        Map.get(export, :sensitivity_at_or_above)
      ) and
      request.model not in Map.get(export, :allow_models, [])
  end

  defp tool_access_blocked?(request, config) do
    access = get_in(config, [:pii, :tool_access]) || %{}

    Map.get(access, :enabled, false) and
      sensitivity_at_or_above?(
        request.highest_sensitivity,
        Map.get(access, :sensitivity_at_or_above)
      ) and
      not allowed_tool_access?(request, access)
  end

  defp allowed_tool_access?(request, access) do
    request.qualified_tool in Map.get(access, :allowed_tools, []) or
      request.tool in Map.get(access, :allowed_tools, []) or
      request.agent in Map.get(access, :allowed_agents, []) or
      to_string(request.agent) in Enum.map(Map.get(access, :allowed_agents, []), &to_string/1) or
      request.data_class in Map.get(access, :allowed_data_classes, [])
  end

  defp tenant_required?(surface, config) do
    surface in Map.get(config.tenant, :required_surfaces, [])
  end

  defp rule_matches(surface, request, rules) do
    rules
    |> Enum.with_index()
    |> Enum.flat_map(fn {rule, index} ->
      normalized = normalize_rule(rule)

      if matches_rule?(surface, request, normalized) do
        [
          %{
            decision: normalized.decision,
            reason: normalized.reason || "rule_#{index}"
          }
        ]
      else
        []
      end
    end)
  end

  defp choose_trace(surface, request, matches) do
    winner =
      Enum.reduce(matches, %{decision: :allow, reason: "default_allow"}, fn match, current ->
        if decision_rank(match.decision) > decision_rank(current.decision),
          do: match,
          else: current
      end)

    %{
      surface: surface,
      decision: winner.decision,
      reason: winner.reason,
      model: Map.get(request, :model),
      tool: Map.get(request, :tool),
      qualified_tool: Map.get(request, :qualified_tool),
      source: Map.get(request, :source),
      server: Map.get(request, :server),
      data_class: Map.get(request, :data_class),
      tenant: Map.get(request, :tenant),
      agent: Map.get(request, :agent),
      step: Map.get(request, :step),
      sensitivity: request.highest_sensitivity,
      source_kinds: request.source_kinds,
      matches: matches
    }
  end

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:security_policy)
      |> normalize_config()

    merge_config(global, per_call)
  end

  defp normalize_config(nil), do: %{}
  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}

  defp normalize_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "security policy config must be a keyword list, map, boolean, or nil, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      emit_telemetry: normalize_booleanish(fetch_value(config, :emit_telemetry)),
      tenant: normalize_tenant_config(fetch_value(config, :tenant)),
      pii: normalize_pii_config(fetch_value(config, :pii)),
      rules: normalize_rules(fetch_value(config, :rules))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "security policy config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(
      :tenant,
      @default_config.tenant
      |> Map.merge(Map.get(global, :tenant, %{}))
      |> Map.merge(Map.get(per_call, :tenant, %{}))
    )
    |> Map.put(
      :pii,
      @default_config.pii
      |> Map.merge(Map.get(global, :pii, %{}))
      |> then(fn pii ->
        pii
        |> Map.put(
          :model_export,
          @default_config.pii.model_export
          |> Map.merge(get_in(global, [:pii, :model_export]) || %{})
          |> Map.merge(get_in(per_call, [:pii, :model_export]) || %{})
        )
        |> Map.put(
          :tool_access,
          @default_config.pii.tool_access
          |> Map.merge(get_in(global, [:pii, :tool_access]) || %{})
          |> Map.merge(get_in(per_call, [:pii, :tool_access]) || %{})
        )
      end)
    )
    |> Map.put(:rules, Map.get(per_call, :rules, Map.get(global, :rules, [])))
  end

  defp normalize_tenant_config(nil), do: nil

  defp normalize_tenant_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_tenant_config()
  end

  defp normalize_tenant_config(%{} = config) do
    %{
      required_surfaces: normalize_surfaces(fetch_value(config, :required_surfaces))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_tenant_config(_other), do: nil

  defp normalize_pii_config(nil), do: nil

  defp normalize_pii_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_pii_config()
  end

  defp normalize_pii_config(%{} = config) do
    %{
      model_export: normalize_pii_rule(fetch_value(config, :model_export), :model),
      tool_access: normalize_pii_rule(fetch_value(config, :tool_access), :tool)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_pii_config(_other), do: nil

  defp normalize_pii_rule(nil, _mode), do: nil

  defp normalize_pii_rule(config, mode) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_pii_rule(mode)
  end

  defp normalize_pii_rule(%{} = config, :model) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      sensitivity_at_or_above:
        normalize_sensitivity(fetch_value(config, :sensitivity_at_or_above)),
      allow_models: normalize_string_list(fetch_value(config, :allow_models))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_pii_rule(%{} = config, :tool) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      sensitivity_at_or_above:
        normalize_sensitivity(fetch_value(config, :sensitivity_at_or_above)),
      allowed_tools: normalize_string_list(fetch_value(config, :allowed_tools)),
      allowed_agents: normalize_string_list(fetch_value(config, :allowed_agents)),
      allowed_data_classes: normalize_data_classes(fetch_value(config, :allowed_data_classes))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_pii_rule(_other, _mode), do: nil

  defp normalize_rules(nil), do: []
  defp normalize_rules(rules) when is_list(rules), do: Enum.map(rules, &normalize_rule/1)
  defp normalize_rules(_other), do: []

  defp normalize_rule(rule) when is_list(rule) do
    rule |> Enum.into(%{}) |> normalize_rule()
  end

  defp normalize_rule(%{} = rule) do
    %{
      surface: normalize_surface(fetch_value(rule, :surface)) || :all,
      decision: normalize_decision(fetch_value(rule, :decision), :allow),
      reason: normalize_string(fetch_value(rule, :reason)),
      model: normalize_string(fetch_value(rule, :model)),
      models: normalize_string_list(fetch_value(rule, :models)),
      tool: normalize_string(fetch_value(rule, :tool)),
      tools: normalize_string_list(fetch_value(rule, :tools)),
      data_class: normalize_data_classes(fetch_value(rule, :data_class)),
      agent: normalize_string(fetch_value(rule, :agent)),
      tenant: normalize_string(fetch_value(rule, :tenant)),
      sensitivity_at_or_above: normalize_sensitivity(fetch_value(rule, :sensitivity_at_or_above))
    }
  end

  defp normalize_rule(_other), do: %{}

  defp matches_rule?(surface, request, rule) do
    rule.surface in [:all, surface] and
      matches_string_rule?(Map.get(request, :model), rule.model, rule.models) and
      matches_string_rule?(Map.get(request, :qualified_tool), rule.tool, rule.tools) and
      matches_string_rule?(
        Map.get(request, :agent) && to_string(Map.get(request, :agent)),
        rule.agent,
        nil
      ) and
      matches_string_rule?(Map.get(request, :tenant), rule.tenant, nil) and
      matches_data_class?(Map.get(request, :data_class), rule.data_class) and
      sensitivity_at_or_above?(request.highest_sensitivity, rule.sensitivity_at_or_above)
  end

  defp matches_string_rule?(_value, nil, nil), do: true
  defp matches_string_rule?(value, single, _many) when is_binary(single), do: value == single
  defp matches_string_rule?(value, _single, many) when is_list(many), do: value in many
  defp matches_string_rule?(_value, _single, _many), do: true

  defp matches_data_class?(_value, nil), do: true
  defp matches_data_class?(value, values) when is_list(values), do: value in values

  defp maybe_add_match(matches, true, match), do: matches ++ [match]
  defp maybe_add_match(matches, _predicate, _match), do: matches

  defp privacy_sensitivities(%{detections: detections}) when is_list(detections) do
    detections
    |> Enum.map(&Map.get(&1, :sensitivity))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp privacy_sensitivities(_state), do: []

  defp privacy_source_kinds(%{detections: detections}) when is_list(detections) do
    detections
    |> Enum.map(&Map.get(&1, :source_kind))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp privacy_source_kinds(_state), do: []

  defp highest_sensitivity(privacy_state) do
    privacy_state
    |> privacy_sensitivities()
    |> Enum.max_by(&Map.get(@risk_order, &1, -1), fn -> nil end)
  end

  defp sensitivity_at_or_above?(_value, nil), do: true
  defp sensitivity_at_or_above?(nil, _threshold), do: false

  defp sensitivity_at_or_above?(value, threshold) do
    Map.get(@risk_order, value, -1) >= Map.get(@risk_order, threshold, 10)
  end

  defp decision_rank(:allow), do: 0
  defp decision_rank(:ask), do: 1
  defp decision_rank(:deny), do: 2

  defp maybe_emit(trace, %{emit_telemetry: true}) do
    :telemetry.execute(
      [:synaptic, :security_policy, :decision],
      %{count: 1},
      %{
        surface: trace.surface,
        decision: trace.decision,
        reason: trace.reason,
        model: trace.model,
        tool: trace.tool,
        source: trace.source,
        data_class: trace.data_class,
        tenant: trace.tenant,
        sensitivity: trace.sensitivity
      }
    )
  end

  defp maybe_emit(_trace, _config), do: :ok

  defp normalize_decision(value, fallback)
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

  defp normalize_surface(value) when value in [:prompt, :tool, :all], do: value

  defp normalize_surface(value) when is_binary(value) do
    case String.downcase(value) do
      "prompt" -> :prompt
      "tool" -> :tool
      "all" -> :all
      _ -> nil
    end
  end

  defp normalize_surface(_value), do: nil

  defp normalize_surfaces(nil), do: nil
  defp normalize_surfaces(values) when is_list(values), do: Enum.map(values, &normalize_surface/1)
  defp normalize_surfaces(value), do: [normalize_surface(value)]

  defp normalize_sensitivity(value) when value in [:pii, :restricted_pii, :secret], do: value

  defp normalize_sensitivity(value) when is_binary(value) do
    case String.downcase(value) do
      "pii" -> :pii
      "restricted_pii" -> :restricted_pii
      "secret" -> :secret
      _ -> nil
    end
  end

  defp normalize_sensitivity(_value), do: nil

  defp normalize_data_classes(nil), do: nil

  defp normalize_data_classes(values) when is_list(values),
    do: Enum.map(values, &normalize_data_class/1)

  defp normalize_data_classes(value), do: [normalize_data_class(value)]

  defp normalize_data_class(value) when is_atom(value), do: value
  defp normalize_data_class(value) when is_binary(value), do: value
  defp normalize_data_class(value), do: to_string(value)

  defp normalize_booleanish(nil), do: nil
  defp normalize_booleanish(value) when value in [true, false], do: value
  defp normalize_booleanish("true"), do: true
  defp normalize_booleanish("false"), do: false
  defp normalize_booleanish(_value), do: nil

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

  defp normalize_string_list(nil), do: nil
  defp normalize_string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_string_list(value), do: [to_string(value)]

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
