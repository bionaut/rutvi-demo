defmodule Synaptic.Security do
  @moduledoc false

  require Logger

  alias Synaptic.{
    ActionControls,
    Audit,
    ConnectorGateway,
    ContextHygiene,
    EgressPolicy,
    Factuality,
    MCPGovernance,
    PolicyHooks,
    Privacy,
    PromptSecurity,
    RuntimeSecurity,
    Sanitization,
    SecurityPolicy,
    ToolPolicy,
    Validation
  }

  @surfaces [:chat, :workflow, :judgment]
  @profile_names [:developer, :production, :high_assurance, :regulated]
  @diagnostic_modes [:ignore, :warn, :error]

  @default_diagnostics %{
    enabled: true,
    on_error: :warn,
    emit_warnings: true,
    emit_on_startup: true
  }

  @profiles %{
    developer: %{
      description: "Low-friction local development with maximum flexibility.",
      defaults: %{
        chat: [],
        workflow: []
      },
      expectations: %{
        chat: %{},
        workflow: %{}
      }
    },
    production: %{
      description:
        "Balanced production defaults with safer prompt handling and audit visibility.",
      defaults: %{
        chat: [
          validation: [tools: true],
          sanitization: [enabled: true],
          prompt_security: [enabled: true],
          context_hygiene: [enabled: true],
          audit: [enabled: true]
        ],
        workflow: [
          audit: [enabled: true],
          runtime_security: [enabled: true]
        ]
      },
      expectations: %{
        chat: %{
          required_boundaries: [:prompt_security, :audit],
          recommended_boundaries: [:sanitization, :context_hygiene],
          require_tool_validation: true
        },
        workflow: %{
          required_boundaries: [:audit],
          recommended_boundaries: [:runtime_security]
        }
      }
    },
    high_assurance: %{
      description: "Stricter posture for sensitive tool use and lower-trust environments.",
      defaults: %{
        chat: [
          validation: [tools: true],
          sanitization: [enabled: true, tool_results: [enabled: true]],
          privacy: [enabled: true],
          prompt_security: [enabled: true, response: [on_detection: :error]],
          egress: [
            enabled: true,
            mcp: [allow_hosts: []]
          ],
          connector_gateway: [
            enabled: true,
            auth: [forbid_passthrough_headers: true],
            tls: [require_https: true],
            session_binding: [enabled: true]
          ],
          policy: [enabled: true, require_approval: [destructive: true, risk_at_or_above: :high]],
          action_controls: [
            enabled: true,
            idempotency: [
              enabled: true,
              require_for: [destructive: true, risk_at_or_above: :high]
            ]
          ],
          context_hygiene: [enabled: true, tool_results: [summarize_sensitive_previews: true]],
          audit: [enabled: true]
        ],
        workflow: [
          validation_defaults: [input: :subset, output: :strict, resume: :strict],
          audit: [enabled: true],
          runtime_security: [
            enabled: true,
            snapshot: [redact: true],
            retention: [purge_context_on_terminal: true]
          ]
        ]
      },
      expectations: %{
        chat: %{
          required_boundaries: [
            :sanitization,
            :privacy,
            :prompt_security,
            :egress,
            :connector_gateway,
            :tool_policy,
            :action_controls,
            :context_hygiene,
            :audit
          ],
          require_tool_validation: true
        },
        workflow: %{
          required_boundaries: [:audit, :runtime_security],
          require_step_validation: true
        }
      }
    },
    regulated: %{
      description: "High-assurance posture with tenant-aware controls and answer verification.",
      defaults: %{
        chat: [
          validation: [tools: true],
          sanitization: [enabled: true, tool_results: [enabled: true]],
          privacy: [enabled: true, prompt: [derived_facts: true]],
          prompt_security: [enabled: true, response: [on_detection: :error]],
          egress: [
            enabled: true,
            mcp: [allow_hosts: []]
          ],
          connector_gateway: [
            enabled: true,
            managed_only: true,
            auth: [forbid_passthrough_headers: true],
            tls: [require_https: true],
            session_binding: [enabled: true, require_run_id: true]
          ],
          policy: [
            enabled: true,
            require_approval: [destructive: true, risk_at_or_above: :medium]
          ],
          security_policy: [
            enabled: true,
            tenant: [required_surfaces: [:prompt, :tool]]
          ],
          action_controls: [
            enabled: true,
            idempotency: [
              enabled: true,
              require_for: [destructive: true, risk_at_or_above: :medium]
            ]
          ],
          context_hygiene: [enabled: true, tool_results: [summarize_sensitive_previews: true]],
          factuality: [
            enabled: true,
            checks: [require_provenance: true],
            verification: [enabled: true]
          ],
          audit: [enabled: true]
        ],
        workflow: [
          validation_defaults: [input: :strict, output: :strict, resume: :strict],
          audit: [enabled: true],
          runtime_security: [
            enabled: true,
            snapshot: [redact: true],
            retention: [purge_context_on_terminal: true]
          ]
        ]
      },
      expectations: %{
        chat: %{
          required_boundaries: [
            :sanitization,
            :privacy,
            :prompt_security,
            :egress,
            :connector_gateway,
            :tool_policy,
            :security_policy,
            :action_controls,
            :context_hygiene,
            :factuality,
            :audit
          ],
          require_tool_validation: true,
          require_tenant: true,
          require_verifier: true
        },
        workflow: %{
          required_boundaries: [:audit, :runtime_security],
          require_step_validation: true
        }
      }
    }
  }

  # Judgments export structured data but do not generate prose or invoke tools.
  @judgment_boundaries [
    :sanitization,
    :privacy,
    :egress,
    :connector_gateway,
    :security_policy,
    :audit
  ]
  @profiles Map.new(@profiles, fn {name, profile} ->
              defaults = Keyword.take(profile.defaults.chat, @judgment_boundaries)
              expectations = profile.expectations.chat

              judgment_expectations = %{
                required_boundaries:
                  Enum.filter(
                    Map.get(expectations, :required_boundaries, []),
                    &(&1 in @judgment_boundaries)
                  ),
                recommended_boundaries:
                  Enum.filter(
                    Map.get(expectations, :recommended_boundaries, []),
                    &(&1 in @judgment_boundaries)
                  ),
                require_tenant: Map.get(expectations, :require_tenant, false)
              }

              {name,
               %{
                 profile
                 | defaults: Map.put(profile.defaults, :judgment, defaults),
                   expectations: Map.put(profile.expectations, :judgment, judgment_expectations)
               }}
            end)

  def available_profiles, do: @profile_names

  def profile(name) when is_atom(name), do: Map.get(@profiles, name)

  def profile(name) when is_binary(name) do
    Enum.find_value(@profile_names, fn profile_name ->
      if Atom.to_string(profile_name) == name, do: Map.get(@profiles, profile_name)
    end)
  end

  def profile(_name), do: nil

  def explain(surface, opts \\ []) when surface in @surfaces and is_list(opts) do
    surface
    |> build_report(opts)
    |> public_report()
  end

  def prepare_opts(surface, opts \\ []) when surface in @surfaces and is_list(opts) do
    report = build_report(surface, opts)

    cond do
      report.diagnostics.enabled and report.diagnostics.errors != [] and
          report.diagnostics.on_error == :error ->
        {:error, {:security_configuration_failed, public_report(report)}}

      true ->
        {:ok, report.prepared_opts, report}
    end
  end

  defp build_report(surface, opts) do
    case build_context(surface, opts) do
      {:ok, context} -> finalize_report(context)
      {:error, diagnostic} -> error_report(surface, opts, diagnostic)
    end
  end

  def maybe_attach_metadata({:ok, content}, report)
      when is_map(report) and report.security_explain do
    {:ok, content, %{security: public_report(report)}}
  end

  def maybe_attach_metadata({:ok, content, meta}, report)
      when is_map(meta) and is_map(report) and report.security_explain do
    {:ok, content, Map.put(meta, :security, public_report(report))}
  end

  def maybe_attach_metadata(result, _report), do: result

  def startup_diagnostics do
    Enum.map(@surfaces, &public_report(explain(&1, [])))
  end

  def maybe_emit_startup_diagnostics do
    for report <- Enum.map(@surfaces, &build_report(&1, [])) |> Enum.map(&public_report/1),
        report.diagnostics.enabled,
        report.diagnostics.emit_on_startup,
        report.diagnostics.errors != [] or
          (report.diagnostics.emit_warnings and report.diagnostics.warnings != []) do
      emit_startup_report(report)
    end

    :ok
  end

  defp build_context(surface, opts) do
    with {:ok, profile_name, profile_source} <- resolve_profile(opts),
         {:ok, prepared_opts} <- apply_profile_defaults(surface, opts, profile_name) do
      diagnostics_config = resolve_diagnostics_config(opts)

      {:ok,
       %{
         surface: surface,
         original_opts: opts,
         prepared_opts: prepared_opts,
         security_explain: Keyword.get(prepared_opts, :security_explain, false),
         profile: profile_name,
         profile_source: profile_source,
         profile_description: profile_description(profile_name),
         diagnostics_config: diagnostics_config
       }}
    end
  end

  defp finalize_report(context) do
    boundary_summary = boundaries(context.surface, context.prepared_opts)
    diagnostics = diagnostics(context.surface, context, boundary_summary)

    Map.merge(context, %{
      boundaries: boundary_summary,
      diagnostics: diagnostics
    })
  end

  defp error_report(surface, opts, diagnostic) do
    diagnostics_config = resolve_diagnostics_config(opts)

    %{
      surface: surface,
      original_opts: opts,
      prepared_opts: opts,
      security_explain: Keyword.get(opts, :security_explain, false),
      profile: nil,
      profile_source: :none,
      profile_description: nil,
      boundaries: %{},
      diagnostics: Map.merge(diagnostics_config, %{errors: [diagnostic], warnings: []})
    }
  end

  defp public_report(report) do
    %{
      surface: report.surface,
      profile:
        if report.profile do
          %{
            name: report.profile,
            source: report.profile_source,
            description: report.profile_description
          }
        else
          nil
        end,
      boundaries: report.boundaries,
      diagnostics:
        Map.take(report.diagnostics, [
          :enabled,
          :on_error,
          :emit_warnings,
          :emit_on_startup,
          :errors,
          :warnings
        ])
    }
  end

  defp resolve_profile(opts) do
    global = Application.get_env(:synaptic, __MODULE__, [])
    explicit = Keyword.get(opts, :security_profile, :__unset__)

    cond do
      explicit == false ->
        {:ok, nil, :explicit}

      explicit not in [:__unset__, nil] ->
        normalize_profile(explicit, :explicit)

      true ->
        global
        |> Keyword.get(:profile)
        |> normalize_profile(:global)
    end
  end

  defp normalize_profile(nil, _source), do: {:ok, nil, :none}

  defp normalize_profile(name, source) when is_binary(name) do
    try do
      name
      |> String.to_existing_atom()
      |> normalize_profile(source)
    rescue
      ArgumentError ->
        {:error,
         %{
           code: :unknown_profile,
           message: "Unknown security profile #{inspect(name)}.",
           details: %{available_profiles: @profile_names}
         }}
    end
  end

  defp normalize_profile(name, source) when is_atom(name) do
    if name in @profile_names do
      {:ok, name, source}
    else
      {:error,
       %{
         code: :unknown_profile,
         message: "Unknown security profile #{inspect(name)}.",
         details: %{available_profiles: @profile_names}
       }}
    end
  end

  defp normalize_profile(other, _source) do
    {:error,
     %{
       code: :invalid_profile,
       message: "security_profile must be an atom, string, false, or nil.",
       details: %{value: inspect(other)}
     }}
  end

  defp apply_profile_defaults(_surface, opts, nil), do: {:ok, opts}

  defp apply_profile_defaults(surface, opts, profile_name) do
    defaults =
      @profiles
      |> Map.fetch!(profile_name)
      |> get_in([:defaults, surface])
      |> List.wrap()

    {:ok, deep_merge_keyword(defaults, opts)}
  end

  defp profile_description(nil), do: nil

  defp profile_description(name) do
    @profiles
    |> Map.get(name, %{})
    |> Map.get(:description)
  end

  defp resolve_diagnostics_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> Keyword.get(:diagnostics, [])

    per_call = Keyword.get(opts, :security_diagnostics, [])

    @default_diagnostics
    |> Map.merge(normalize_diagnostics(global))
    |> Map.merge(normalize_diagnostics(per_call))
    |> Map.put(:errors, [])
    |> Map.put(:warnings, [])
  end

  defp normalize_diagnostics(nil), do: %{}
  defp normalize_diagnostics(false), do: %{enabled: false}
  defp normalize_diagnostics(true), do: %{enabled: true}

  defp normalize_diagnostics(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "security diagnostics config must be a keyword list, boolean, or nil, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_diagnostics()
  end

  defp normalize_diagnostics(%{} = config) do
    %{
      enabled: booleanish(Map.get(config, :enabled)),
      on_error: normalize_mode(Map.get(config, :on_error)),
      emit_warnings: booleanish(Map.get(config, :emit_warnings)),
      emit_on_startup: booleanish(Map.get(config, :emit_on_startup))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_diagnostics(other) do
    raise ArgumentError,
          "security diagnostics config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp boundaries(:chat, opts) do
    sanitization = Sanitization.new(opts)
    privacy = Privacy.new(opts)
    prompt_security = PromptSecurity.new(opts)
    tool_policy = ToolPolicy.new(opts)
    action_controls = ActionControls.new(opts)
    hooks = PolicyHooks.new(opts)
    context_hygiene = ContextHygiene.new(opts)
    factuality = Factuality.new(opts)
    audit = Audit.new(opts)
    egress = EgressPolicy.config(opts)
    connector_gateway = ConnectorGateway.config(opts)

    %{
      validation: %{
        tools: Validation.tool_validation_enabled?(opts)
      },
      sanitization: %{
        enabled: Sanitization.enabled?(sanitization),
        prompt: Map.take(sanitization.config.prompt, [:enabled, :roles, :types]),
        tools: Map.take(sanitization.config.tools, [:enabled, :infer_fields]),
        tool_results: Map.take(sanitization.config.tool_results, [:enabled])
      },
      privacy: %{
        enabled: Privacy.enabled?(privacy),
        prompt:
          Map.take(privacy.config.prompt, [
            :enabled,
            :default_action,
            :derived_facts,
            :include_tokens_in_facts
          ]),
        output: Map.take(privacy.config.output, [:enabled, :default_action, :rehydrate]),
        return_metadata: privacy.config.return_metadata
      },
      prompt_security: %{
        enabled: PromptSecurity.enabled?(prompt_security),
        prompt: Map.take(prompt_security.config.prompt, [:enabled, :inject_trust_boundaries]),
        response: Map.take(prompt_security.config.response, [:on_detection]),
        tool_policy:
          Map.take(prompt_security.config.tool_policy, [
            :enabled,
            :deny_categories,
            :allow_read_only
          ]),
        return_metadata: prompt_security.config.return_metadata
      },
      egress: %{
        enabled: egress.enabled,
        openai:
          Map.take(egress.surfaces.openai, [:allow_hosts, :resolve_dns, :allowed_mime_types]),
        mcp:
          Map.take(egress.surfaces.mcp, [
            :allow_hosts,
            :allow_localhost,
            :allow_private_network,
            :resolve_dns,
            :allowed_mime_types
          ]),
        voice: Map.take(egress.surfaces.voice, [:allow_hosts, :resolve_dns, :allowed_mime_types])
      },
      connector_gateway: %{
        enabled: connector_gateway.enabled,
        managed_only: connector_gateway.managed_only,
        auth:
          Map.take(connector_gateway.auth, [
            :forbid_passthrough_headers,
            :allowed_passthrough_headers
          ]),
        tls: Map.take(connector_gateway.tls, [:require_https, :allow_http_hosts]),
        session_binding:
          Map.take(connector_gateway.session_binding, [:enabled, :header, :require_run_id]),
        rate_limit_rules: length(connector_gateway.rate_limits)
      },
      tool_policy: %{
        enabled: ToolPolicy.enabled?(tool_policy),
        default_decision: tool_policy.config.default_decision,
        require_approval: tool_policy.config.require_approval,
        return_decisions: tool_policy.config.return_decisions
      },
      action_controls: %{
        enabled: ActionControls.enabled?(action_controls),
        idempotency:
          Map.take(action_controls.config.idempotency, [
            :enabled,
            :duplicate_behavior,
            :require_for
          ]),
        retries: Map.take(action_controls.config.retries, [:enabled, :max_attempts, :sources]),
        rate_limit_rules: length(action_controls.config.rate_limits),
        blast_radius_rules: length(action_controls.config.blast_radius),
        return_metadata: action_controls.config.return_metadata
      },
      security_policy: summarize_security_policy(opts),
      hooks: %{
        enabled: PolicyHooks.enabled?(hooks),
        managed_only: hooks.managed_only,
        failure_policy: hooks.failure_policy
      },
      mcp_governance: summarize_mcp_governance(opts),
      context_hygiene: %{
        enabled: ContextHygiene.enabled?(context_hygiene),
        prompt: Map.take(context_hygiene.config.prompt, [:static_roles]),
        tool_results:
          Map.take(context_hygiene.config.tool_results, [
            :enabled,
            :spill_oversized,
            :compact_older,
            :keep_recent,
            :summarize_sensitive_previews
          ]),
        return_metadata: context_hygiene.config.return_metadata
      },
      factuality: %{
        enabled: Factuality.enabled?(factuality),
        prompt: Map.take(factuality.config.prompt, [:enabled, :inject_response_policy]),
        checks:
          Map.take(factuality.config.checks, [
            :require_evidence,
            :require_citations,
            :require_provenance,
            :detect_unsupported_claims
          ]),
        verification:
          Map.take(factuality.config.verification, [:enabled, :verifier, :on_failure]),
        return_metadata: factuality.config.return_metadata
      },
      audit: %{
        enabled: Audit.enabled?(audit),
        retention_ms: audit.config.retention_ms,
        categories: audit.config.categories,
        return_metadata: audit.config.return_metadata
      }
    }
  end

  defp boundaries(:judgment, opts) do
    boundaries = Map.take(boundaries(:chat, opts), @judgment_boundaries)
    egress = EgressPolicy.config(opts)

    Map.put(boundaries, :egress, %{
      enabled: egress.enabled,
      jev: EgressPolicy.effective_config(:jev, opts)
    })
  end

  defp boundaries(:workflow, opts) do
    runtime_security = RuntimeSecurity.new(opts)
    audit = Audit.new(opts)

    %{
      validation: %{
        step_defaults: Validation.runtime_step_defaults(opts)
      },
      audit: %{
        enabled: Audit.enabled?(audit),
        retention_ms: audit.config.retention_ms,
        categories: audit.config.categories,
        return_metadata: audit.config.return_metadata
      },
      runtime_security: %{
        enabled: RuntimeSecurity.enabled?(runtime_security),
        history: Map.take(runtime_security.config.history, [:redact, :max_entries]),
        events: Map.take(runtime_security.config.events, [:redact]),
        snapshot: Map.take(runtime_security.config.snapshot, [:redact]),
        retention:
          Map.take(runtime_security.config.retention, [
            :shutdown_after_ms,
            :purge_context_on_terminal
          ])
      }
    }
  end

  defp summarize_security_policy(opts) do
    config = SecurityPolicy.config(opts)

    %{
      enabled: config.enabled,
      tenant: config.tenant,
      pii: %{
        model_export: Map.take(config.pii.model_export, [:enabled, :sensitivity_at_or_above]),
        tool_access:
          Map.take(config.pii.tool_access, [
            :enabled,
            :sensitivity_at_or_above,
            :allowed_data_classes
          ])
      },
      rules: length(config.rules)
    }
  end

  defp summarize_mcp_governance(opts) do
    config = MCPGovernance.config(opts)

    %{
      enabled: config.enabled,
      managed_only: config.managed_only,
      allow_servers: config.allow_servers,
      deny_servers: config.deny_servers
    }
  end

  defp diagnostics(surface, context, boundaries) do
    profile_expectations =
      if context.profile do
        @profiles
        |> Map.fetch!(context.profile)
        |> get_in([:expectations, surface])
      else
        %{}
      end

    errors =
      []
      |> maybe_add(boundaries_error(boundaries, profile_expectations, surface))
      |> maybe_add(functional_errors(surface, context.prepared_opts, boundaries))

    warnings =
      []
      |> maybe_add(boundaries_warning(boundaries, profile_expectations))
      |> maybe_add(functional_warnings(surface, context.prepared_opts, boundaries))

    Map.merge(context.diagnostics_config, %{
      errors: dedupe_diagnostics(List.flatten(errors)),
      warnings: dedupe_diagnostics(List.flatten(warnings))
    })
  end

  defp boundaries_error(boundaries, expectations, surface) do
    []
    |> maybe_add(required_boundary_errors(boundaries, expectations))
    |> maybe_add(required_tool_validation_error(boundaries, expectations))
    |> maybe_add(required_step_validation_error(boundaries, expectations))
    |> maybe_add(required_tenant_error(surface, expectations, boundaries))
    |> maybe_add(required_verifier_error(expectations, boundaries))
  end

  defp boundaries_warning(boundaries, expectations) do
    recommended = Map.get(expectations, :recommended_boundaries, [])

    Enum.flat_map(recommended, fn boundary ->
      if boundary_enabled?(boundaries, boundary) do
        []
      else
        [
          %{
            code: :recommended_boundary_disabled,
            message:
              "Recommended security boundary #{inspect(boundary)} is disabled for this posture.",
            details: %{boundary: boundary}
          }
        ]
      end
    end)
  end

  defp required_boundary_errors(boundaries, expectations) do
    expectations
    |> Map.get(:required_boundaries, [])
    |> Enum.flat_map(fn boundary ->
      if boundary_enabled?(boundaries, boundary) do
        []
      else
        [
          %{
            code: :required_boundary_disabled,
            message:
              "Required security boundary #{inspect(boundary)} is disabled for this posture.",
            details: %{boundary: boundary}
          }
        ]
      end
    end)
  end

  defp required_tool_validation_error(boundaries, %{require_tool_validation: true}) do
    if get_in(boundaries, [:validation, :tools]) do
      []
    else
      [
        %{
          code: :tool_validation_disabled,
          message: "This posture expects tool schema validation to be enabled.",
          details: %{boundary: :validation}
        }
      ]
    end
  end

  defp required_tool_validation_error(_boundaries, _expectations), do: []

  defp required_step_validation_error(boundaries, %{require_step_validation: true}) do
    defaults = get_in(boundaries, [:validation, :step_defaults]) || []

    if Enum.any?(defaults, fn {_surface, mode} -> mode != :off end) do
      []
    else
      [
        %{
          code: :step_validation_disabled,
          message: "This posture expects workflow validation defaults to be enabled.",
          details: %{boundary: :validation}
        }
      ]
    end
  end

  defp required_step_validation_error(_boundaries, _expectations), do: []

  defp required_tenant_error(surface, %{require_tenant: true}, boundaries) do
    required_surfaces = get_in(boundaries, [:security_policy, :tenant, :required_surfaces]) || []

    tenant_required =
      case surface do
        :chat -> Enum.any?(required_surfaces, &(&1 in [:prompt, :tool]))
        :judgment -> :prompt in required_surfaces
        :workflow -> false
      end

    if tenant_required do
      []
    else
      [
        %{
          code: :tenant_not_enforced,
          message: "This posture expects tenant-aware controls on #{inspect(surface)} paths.",
          details: %{surface: surface}
        }
      ]
    end
  end

  defp required_tenant_error(_surface, _expectations, _boundaries), do: []

  defp required_verifier_error(%{require_verifier: true}, boundaries) do
    if get_in(boundaries, [:factuality, :verification, :enabled]) and
         is_function(get_in(boundaries, [:factuality, :verification, :verifier]), 1) do
      []
    else
      [
        %{
          code: :verifier_missing,
          message: "This posture expects a factuality verifier callback for critical outputs.",
          details: %{boundary: :factuality}
        }
      ]
    end
  end

  defp required_verifier_error(_expectations, _boundaries), do: []

  defp functional_errors(surface, opts, boundaries) do
    []
    |> maybe_add(missing_tenant_error(surface, opts, boundaries))
    |> maybe_add(missing_verifier_error(boundaries))
  end

  defp functional_warnings(_surface, _opts, boundaries) do
    []
    |> maybe_add(noop_tool_policy_warning(boundaries))
    |> maybe_add(noop_action_controls_warning(boundaries))
    |> maybe_add(prompt_security_warning(boundaries))
    |> maybe_add(egress_warning(boundaries))
    |> maybe_add(connector_gateway_warning(boundaries))
  end

  defp missing_tenant_error(surface, opts, boundaries) do
    required_surfaces = get_in(boundaries, [:security_policy, :tenant, :required_surfaces]) || []
    tenant = Keyword.get(opts, :tenant)

    require_tenant? =
      case surface do
        :chat -> Enum.any?(required_surfaces, &(&1 in [:prompt, :tool]))
        :judgment -> :prompt in required_surfaces
        :workflow -> false
      end

    if require_tenant? and not present_string?(tenant) do
      [
        %{
          code: :tenant_missing,
          message: "A tenant is required for this security configuration.",
          details: %{surface: surface}
        }
      ]
    else
      []
    end
  end

  defp missing_verifier_error(boundaries) do
    verification = get_in(boundaries, [:factuality, :verification]) || %{}

    if verification[:enabled] && not is_function(verification[:verifier], 1) do
      [
        %{
          code: :verifier_missing,
          message: "Factuality verification is enabled but no verifier callback is configured.",
          details: %{boundary: :factuality}
        }
      ]
    else
      []
    end
  end

  defp noop_tool_policy_warning(boundaries) do
    tool_policy = Map.get(boundaries, :tool_policy, %{})
    require_approval = Map.get(tool_policy, :require_approval, %{})

    cond do
      Map.get(tool_policy, :enabled) != true ->
        []

      Map.get(tool_policy, :default_decision) == :allow and
        Map.get(require_approval, :tools_marked) in [false, nil] and
        Map.get(require_approval, :destructive) in [false, nil] and
          is_nil(Map.get(require_approval, :risk_at_or_above)) ->
        [
          %{
            code: :tool_policy_noop,
            message: "Tool policy is enabled but currently behaves like a broad allow policy.",
            details: %{boundary: :tool_policy}
          }
        ]

      true ->
        []
    end
  end

  defp noop_action_controls_warning(boundaries) do
    action_controls = Map.get(boundaries, :action_controls, %{})
    idempotency = Map.get(action_controls, :idempotency, %{})
    retries = Map.get(action_controls, :retries, %{})

    cond do
      Map.get(action_controls, :enabled) != true ->
        []

      Map.get(idempotency, :enabled) != true and
        Map.get(retries, :enabled) != true and
        Map.get(action_controls, :rate_limit_rules, 0) == 0 and
          Map.get(action_controls, :blast_radius_rules, 0) == 0 ->
        [
          %{
            code: :action_controls_noop,
            message: "Action controls are enabled but no active subcontrols are configured.",
            details: %{boundary: :action_controls}
          }
        ]

      true ->
        []
    end
  end

  defp prompt_security_warning(boundaries) do
    prompt_security = Map.get(boundaries, :prompt_security, %{})
    tool_policy = Map.get(boundaries, :tool_policy, %{})
    response = Map.get(prompt_security, :response, %{})

    if Map.get(prompt_security, :enabled) == true &&
         Map.get(response, :on_detection) == :allow &&
         Map.get(tool_policy, :enabled) != true do
      [
        %{
          code: :prompt_security_permissive,
          message:
            "Prompt security is configured to allow detections, but tool policy is disabled.",
          details: %{boundary: :prompt_security}
        }
      ]
    else
      []
    end
  end

  defp egress_warning(boundaries) do
    egress = Map.get(boundaries, :egress, %{})
    mcp = Map.get(egress, :mcp, %{})

    cond do
      Map.get(egress, :enabled) != true ->
        []

      mcp[:allow_hosts] == [] ->
        [
          %{
            code: :egress_no_mcp_allowlist,
            message:
              "Egress policy is enabled with no MCP host allowlist, so remote MCP HTTP traffic stays blocked until explicitly allowed.",
            details: %{boundary: :egress}
          }
        ]

      true ->
        []
    end
  end

  defp connector_gateway_warning(boundaries) do
    connector_gateway = Map.get(boundaries, :connector_gateway, %{})
    session_binding = Map.get(connector_gateway, :session_binding, %{})

    cond do
      Map.get(connector_gateway, :enabled) != true ->
        []

      session_binding[:enabled] == true and session_binding[:require_run_id] != true ->
        [
          %{
            code: :session_binding_run_id_optional,
            message:
              "Connector gateway session binding is enabled without `require_run_id`, which reduces traceability for remote calls.",
            details: %{boundary: :connector_gateway}
          }
        ]

      true ->
        []
    end
  end

  defp emit_startup_report(report) do
    prefix =
      case report.profile do
        nil -> "[synaptic.security]"
        %{name: name} -> "[synaptic.security][#{name}]"
      end

    Enum.each(report.diagnostics.errors, fn diagnostic ->
      Logger.warning("#{prefix} #{diagnostic.message}")
    end)

    if report.diagnostics.emit_warnings do
      Enum.each(report.diagnostics.warnings, fn diagnostic ->
        Logger.warning("#{prefix} #{diagnostic.message}")
      end)
    end
  end

  defp boundary_enabled?(boundaries, :validation),
    do: get_in(boundaries, [:validation, :tools]) || step_validation_enabled?(boundaries)

  defp boundary_enabled?(boundaries, boundary) do
    get_in(boundaries, [boundary, :enabled]) == true
  end

  defp step_validation_enabled?(boundaries) do
    boundaries
    |> get_in([:validation, :step_defaults])
    |> List.wrap()
    |> Enum.any?(fn {_surface, mode} -> mode != :off end)
  end

  defp maybe_add(list, []), do: list
  defp maybe_add(list, nil), do: list
  defp maybe_add(list, value), do: [value | list]

  defp deep_merge_keyword(left, right) when is_list(left) and is_list(right) do
    left
    |> Enum.into(%{})
    |> deep_merge(Enum.into(right, %{}))
    |> Map.to_list()
  end

  defp deep_merge(%{} = left, %{} = right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp booleanish(nil), do: nil
  defp booleanish(value), do: !!value

  defp normalize_mode(nil), do: nil
  defp normalize_mode(value) when value in @diagnostic_modes, do: value
  defp normalize_mode(_value), do: :warn

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp dedupe_diagnostics(diagnostics) do
    diagnostics
    |> Enum.uniq_by(fn diagnostic ->
      {Map.get(diagnostic, :code), Map.get(diagnostic, :message), Map.get(diagnostic, :details)}
    end)
  end
end
