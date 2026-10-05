defmodule Synaptic.ConnectorGateway do
  @moduledoc false

  @table :synaptic_connector_gateway
  @surfaces [:openai, :mcp, :voice, :jev]
  @sensitive_headers [
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
    "api-key",
    "x-auth-token"
  ]

  @default_config %{
    enabled: false,
    emit_telemetry: true,
    managed_only: false,
    auth: %{
      forbid_passthrough_headers: true,
      allowed_passthrough_headers: [],
      sensitive_headers: @sensitive_headers
    },
    tls: %{
      require_https: false,
      allow_http_hosts: []
    },
    session_binding: %{
      enabled: false,
      header: "x-synaptic-session-binding",
      connector_header: "x-synaptic-connector",
      require_run_id: false
    },
    rate_limits: []
  }

  def config(opts \\ []) when is_list(opts) do
    resolve_config(opts)
  end

  def enabled?(opts \\ []) when is_list(opts) do
    resolve_config(opts).enabled
  end

  def preflight(surface, metadata, opts \\ [])
      when surface in @surfaces and is_map(metadata) and is_list(opts) do
    config = resolve_config(opts)

    if config.enabled do
      ensure_table!()
      request = normalize_request(surface, metadata)

      with :ok <- validate_managed_mode(request, config),
           :ok <- validate_tls(request, config),
           :ok <- validate_passthrough_headers(request, config),
           :ok <- validate_managed_headers(request, config),
           :ok <- validate_rate_limits(request, config),
           :ok <- validate_session_binding_requirements(request, config) do
        extra_headers = session_binding_headers(request, config)
        record_request(request, config)
        emit(:allow, request, nil, config)
        {:ok, extra_headers}
      else
        {:error, detail} ->
          emit(:deny, request, detail, config)
          {:error, {:connector_gateway_blocked, detail}}
      end
    else
      {:ok, []}
    end
  end

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

  defp normalize_request(surface, metadata) do
    %{
      surface: surface,
      connector: metadata[:connector] || surface,
      server: metadata[:server],
      action: metadata[:action],
      url: metadata[:url] |> to_string(),
      method: metadata[:method],
      host: metadata[:host] || host_from_url(metadata[:url]),
      managed: Map.get(metadata, :managed, false),
      run_id: metadata[:run_id],
      tenant: metadata[:tenant],
      passthrough_headers: normalize_headers(metadata[:passthrough_headers] || []),
      agent: metadata[:agent],
      step: metadata[:step]
    }
  end

  defp validate_managed_mode(%{surface: :mcp, managed: false} = request, %{managed_only: true}) do
    error(
      request,
      :unmanaged_connector_blocked,
      "Connector gateway requires MCP connections to come from managed configuration.",
      %{server: request.server}
    )
  end

  defp validate_managed_mode(_request, _config), do: :ok

  defp validate_tls(request, config) do
    tls = config.tls
    uri = URI.parse(request.url)
    scheme = String.downcase(to_string(uri.scheme || ""))
    host = String.downcase(to_string(uri.host || ""))

    if tls.require_https and scheme not in ["https", "wss"] and host not in tls.allow_http_hosts do
      error(
        request,
        :tls_required,
        "Connector gateway requires HTTPS for outbound #{request.surface} traffic.",
        %{host: host, scheme: scheme}
      )
    else
      :ok
    end
  end

  defp validate_passthrough_headers(request, config) do
    auth = config.auth

    if auth.forbid_passthrough_headers do
      allowed = MapSet.new(auth.allowed_passthrough_headers)
      sensitive = MapSet.new(auth.sensitive_headers)

      case Enum.find(request.passthrough_headers, fn {name, _value} ->
             MapSet.member?(sensitive, name) and not MapSet.member?(allowed, name)
           end) do
        {name, _value} ->
          error(
            request,
            :credential_passthrough_forbidden,
            "Connector gateway blocked passthrough credential header #{inspect(name)}.",
            %{header: name}
          )

        nil ->
          :ok
      end
    else
      :ok
    end
  end

  defp validate_managed_headers(request, config) do
    binding = config.session_binding

    if binding.enabled do
      managed_headers = MapSet.new([binding.header, binding.connector_header])

      case Enum.find(request.passthrough_headers, fn {name, _value} ->
             MapSet.member?(managed_headers, name)
           end) do
        {name, _value} ->
          error(
            request,
            :managed_header_passthrough_forbidden,
            "Connector gateway blocked a caller-supplied managed binding header.",
            %{header: name}
          )

        nil ->
          :ok
      end
    else
      :ok
    end
  end

  defp validate_rate_limits(request, config) do
    rules = config.rate_limits

    case Enum.find(rules, fn rule ->
           matches_rule?(request, rule) and
             recent_count(request, rule.window_ms) >= rule.max_calls
         end) do
      nil ->
        :ok

      rule ->
        error(
          request,
          :gateway_rate_limit_exceeded,
          "Connector gateway rate limit exceeded for #{rule_label(rule)}.",
          %{window_ms: rule.window_ms, max_calls: rule.max_calls}
        )
    end
  end

  defp validate_session_binding_requirements(request, config) do
    session_binding = config.session_binding

    if session_binding.enabled and session_binding.require_run_id and blank?(request.run_id) do
      error(
        request,
        :run_id_required,
        "Connector gateway session binding requires a `run_id` for this request.",
        %{surface: request.surface, connector: request.connector}
      )
    else
      :ok
    end
  end

  defp session_binding_headers(request, config) do
    session_binding = config.session_binding

    if session_binding.enabled do
      binding = build_session_binding(request)

      [
        {session_binding.header, binding},
        {session_binding.connector_header, connector_label(request)}
      ]
    else
      []
    end
  end

  defp build_session_binding(request) do
    [
      request.surface,
      request.connector,
      request.server,
      request.action,
      request.run_id,
      request.tenant,
      request.host,
      request.method
    ]
    |> Enum.map(&to_string_or_blank/1)
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:connector_gateway)
      |> normalize_config()

    merge_config(global, per_call)
  end

  defp normalize_config(nil), do: %{}
  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}

  defp normalize_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "connector gateway config must be a keyword list, map, boolean, or nil, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      emit_telemetry: normalize_booleanish(fetch_value(config, :emit_telemetry)),
      managed_only: normalize_booleanish(fetch_value(config, :managed_only)),
      auth: normalize_auth_config(fetch_value(config, :auth)),
      tls: normalize_tls_config(fetch_value(config, :tls)),
      session_binding: normalize_session_binding_config(fetch_value(config, :session_binding)),
      rate_limits: normalize_rate_limits(fetch_value(config, :rate_limits))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "connector gateway config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(
      :auth,
      @default_config.auth
      |> Map.merge(Map.get(global, :auth, %{}))
      |> Map.merge(Map.get(per_call, :auth, %{}))
    )
    |> Map.put(
      :tls,
      @default_config.tls
      |> Map.merge(Map.get(global, :tls, %{}))
      |> Map.merge(Map.get(per_call, :tls, %{}))
    )
    |> Map.put(
      :session_binding,
      @default_config.session_binding
      |> Map.merge(Map.get(global, :session_binding, %{}))
      |> Map.merge(Map.get(per_call, :session_binding, %{}))
    )
  end

  defp normalize_auth_config(nil), do: nil

  defp normalize_auth_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_auth_config()
  end

  defp normalize_auth_config(%{} = config) do
    %{
      forbid_passthrough_headers:
        normalize_booleanish(fetch_value(config, :forbid_passthrough_headers)),
      allowed_passthrough_headers:
        normalize_header_names(fetch_value(config, :allowed_passthrough_headers)),
      sensitive_headers: normalize_header_names(fetch_value(config, :sensitive_headers))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_auth_config(_other), do: nil

  defp normalize_tls_config(nil), do: nil

  defp normalize_tls_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_tls_config()
  end

  defp normalize_tls_config(%{} = config) do
    %{
      require_https: normalize_booleanish(fetch_value(config, :require_https)),
      allow_http_hosts: normalize_hosts(fetch_value(config, :allow_http_hosts))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_tls_config(_other), do: nil

  defp normalize_session_binding_config(nil), do: nil

  defp normalize_session_binding_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_session_binding_config()
  end

  defp normalize_session_binding_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      header: normalize_header_name(fetch_value(config, :header)),
      connector_header: normalize_header_name(fetch_value(config, :connector_header)),
      require_run_id: normalize_booleanish(fetch_value(config, :require_run_id))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_session_binding_config(_other), do: nil

  defp normalize_rate_limits(nil), do: nil

  defp normalize_rate_limits(rules) when is_list(rules) do
    Enum.map(rules, &normalize_rate_limit/1)
  end

  defp normalize_rate_limits(_other), do: nil

  defp normalize_rate_limit(rule) when is_list(rule) do
    rule |> Enum.into(%{}) |> normalize_rate_limit()
  end

  defp normalize_rate_limit(%{} = rule) do
    connector = normalize_optional_atom(fetch_value(rule, :connector))
    surface = normalize_optional_atom(fetch_value(rule, :surface))
    max_calls = normalize_positive_integer(fetch_value(rule, :max_calls))
    window_ms = normalize_positive_integer(fetch_value(rule, :window_ms))

    unless max_calls && window_ms do
      raise ArgumentError,
            "connector gateway rate limits require positive :max_calls and :window_ms values"
    end

    %{
      connector: connector,
      surface: surface,
      server: normalize_optional_string(fetch_value(rule, :server)),
      tenant: normalize_optional_string(fetch_value(rule, :tenant)),
      max_calls: max_calls,
      window_ms: window_ms
    }
  end

  defp matches_rule?(request, rule) do
    matches_optional?(rule.connector, request.connector) and
      matches_optional?(rule.surface, request.surface) and
      matches_optional?(rule.server, request.server) and
      matches_optional?(rule.tenant, request.tenant)
  end

  defp recent_count(request, window_ms) do
    threshold = System.system_time(:millisecond) - window_ms

    entries()
    |> Enum.count(fn entry ->
      entry.inserted_at >= threshold and
        entry.connector == request.connector and
        entry.surface == request.surface and
        entry.server == request.server and
        entry.tenant == request.tenant
    end)
  end

  defp record_request(request, config) do
    max_window =
      config.rate_limits
      |> Enum.map(& &1.window_ms)
      |> Enum.max(fn -> 60_000 end)

    now = System.system_time(:millisecond)

    entry = %{
      connector: request.connector,
      surface: request.surface,
      server: request.server,
      tenant: request.tenant,
      inserted_at: now,
      expires_at: now + max_window
    }

    :ets.insert(@table, {{request.surface, request.connector, now, make_ref()}, entry})
  end

  defp entries do
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

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
      _table -> @table
    end
  end

  defp emit(decision, request, detail, %{emit_telemetry: true}) do
    :telemetry.execute(
      [:synaptic, :connector_gateway, :decision],
      %{count: 1},
      %{
        decision: decision,
        surface: request.surface,
        connector: request.connector,
        server: request.server,
        code: detail && detail.code
      }
    )
  end

  defp emit(_decision, _request, _detail, _config), do: :ok

  defp error(request, code, message, details) do
    {:error,
     %{
       surface: request.surface,
       connector: request.connector,
       server: request.server,
       code: code,
       message: message,
       details: Map.put(details, :url, safe_url(request.url)),
       suggestions: suggestions(code, request)
     }}
  end

  defp suggestions(:credential_passthrough_forbidden, _request) do
    [
      "Remove raw credential headers from MCP or connector config and fetch credentials at runtime instead.",
      "Use generated runtime headers or a broker hook rather than embedding long-lived tokens."
    ]
  end

  defp suggestions(:unmanaged_connector_blocked, _request) do
    [
      "Register the connector under managed Synaptic config before using it in a high-assurance posture.",
      "If this is an intentional temporary exception, run without the managed-only mode in a lower-assurance posture."
    ]
  end

  defp suggestions(:tls_required, _request) do
    [
      "Switch the connector endpoint to HTTPS.",
      "If HTTP is unavoidable for local development, scope the exception to a specific host with `allow_http_hosts`."
    ]
  end

  defp suggestions(:gateway_rate_limit_exceeded, _request) do
    [
      "Wait for the rate-limit window to clear or raise the configured limit intentionally.",
      "Prefer batching or caching repeated connector requests."
    ]
  end

  defp suggestions(:run_id_required, _request) do
    [
      "Pass a stable `run_id` when connector gateway session binding requires it.",
      "If this is an intentional low-traceability flow, relax `require_run_id` only in lower-assurance environments."
    ]
  end

  defp suggestions(_code, _request), do: []

  defp connector_label(request) do
    [request.surface, request.connector, request.server]
    |> Enum.reject(&blank?/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
  end

  defp rule_label(rule) do
    [rule.connector, rule.surface, rule.server, rule.tenant]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.join("/")
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} -> {normalize_header_name(name), value} end)
  end

  defp normalize_header_names(nil), do: nil

  defp normalize_header_names(values) when is_list(values),
    do: Enum.map(values, &normalize_header_name/1)

  defp normalize_header_names(value), do: [normalize_header_name(value)]

  defp normalize_header_name(nil), do: nil

  defp normalize_header_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_hosts(nil), do: nil

  defp normalize_hosts(values) when is_list(values),
    do: Enum.map(values, &normalize_optional_string/1)

  defp normalize_hosts(value), do: [normalize_optional_string(value)]

  defp normalize_optional_atom(nil), do: nil
  defp normalize_optional_atom(value) when is_atom(value), do: value

  defp normalize_optional_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_booleanish(nil), do: nil
  defp normalize_booleanish(value) when is_boolean(value), do: value
  defp normalize_booleanish("true"), do: true
  defp normalize_booleanish("false"), do: false
  defp normalize_booleanish(_value), do: nil

  defp normalize_positive_integer(nil), do: nil
  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value), do: nil

  defp matches_optional?(nil, _value), do: true

  defp matches_optional?(expected, actual)
       when (is_atom(expected) or is_binary(expected)) and
              (is_atom(actual) or is_binary(actual)) do
    String.downcase(to_string(expected)) == String.downcase(to_string(actual))
  end

  defp matches_optional?(expected, actual), do: expected == actual

  defp host_from_url(url) do
    url
    |> to_string()
    |> URI.parse()
    |> Map.get(:host)
    |> normalize_optional_string()
  end

  defp safe_url(url) do
    url
    |> to_string()
    |> URI.parse()
    |> then(fn uri -> %URI{uri | userinfo: nil, query: nil, fragment: nil} end)
    |> URI.to_string()
  end

  defp blank?(value), do: value in [nil, ""]

  defp to_string_or_blank(nil), do: ""
  defp to_string_or_blank(value), do: to_string(value)

  defp fetch_value(config, key) do
    Map.get(config, key) || Map.get(config, to_string(key))
  end
end
