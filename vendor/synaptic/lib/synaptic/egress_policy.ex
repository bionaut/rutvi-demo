defmodule Synaptic.EgressPolicy do
  @moduledoc false

  import Bitwise

  @surfaces [:openai, :mcp, :voice, :jev]
  @methods [:get, :post, :put, :patch, :delete, :head, :options]
  @default_allow_schemes ["https"]

  @default_surface_config %{
    allow_hosts: [],
    deny_hosts: [],
    allow_schemes: @default_allow_schemes,
    allow_methods: [:post],
    allow_private_network: false,
    allow_localhost: false,
    allow_userinfo: false,
    resolve_dns: true,
    dns_resolver: nil,
    max_response_bytes: nil,
    max_content_length: nil,
    max_redirects: 0,
    allowed_mime_types: []
  }

  @default_config %{
    enabled: false,
    emit_telemetry: true,
    return_metadata: false,
    surfaces: %{
      jev: %{
        allow_hosts: ["api.typesafe.ai"],
        allowed_mime_types: ["application/json"]
      },
      openai: %{
        allow_hosts: ["api.openai.com"],
        allowed_mime_types: ["application/json", "text/event-stream"]
      },
      mcp: %{
        allowed_mime_types: ["application/json"]
      },
      voice: %{
        allow_hosts: [
          "api.openai.com",
          "api.elevenlabs.io",
          "generativelanguage.googleapis.com"
        ],
        allow_schemes: ["https", "wss"],
        allow_methods: [:get, :post],
        allowed_mime_types: [
          "application/json",
          "audio/mpeg",
          "audio/wav",
          "audio/l16",
          "audio/ogg",
          "application/octet-stream"
        ]
      }
    }
  }

  def config(opts \\ []) when is_list(opts) do
    resolve_config(opts)
  end

  def enabled?(opts \\ []) when is_list(opts) do
    resolve_config(opts).enabled
  end

  def effective_config(surface, opts \\ []) when surface in @surfaces and is_list(opts) do
    config = resolve_config(opts)
    Map.merge(@default_surface_config, Map.get(config.surfaces, surface, %{}))
  end

  def authorize_request(surface, method, url, opts \\ [], metadata \\ %{})
      when surface in @surfaces and is_list(opts) do
    config = resolve_config(opts)

    if config.enabled do
      request = build_request(surface, method, url, metadata)

      with :ok <- validate_method(request, config),
           {:ok, uri} <- validate_url(request, config),
           :ok <- validate_host(request, uri, config),
           :ok <- validate_scheme(request, uri, config),
           :ok <- validate_userinfo(request, uri, config) do
        emit(:allow, request, nil, config)
        :ok
      else
        {:error, detail} ->
          emit(:deny, request, detail, config)
          {:error, {:egress_blocked, detail}}
      end
    else
      :ok
    end
  end

  def validate_response(surface, url, %Finch.Response{} = response, opts \\ [], metadata \\ %{})
      when surface in @surfaces and is_list(opts) do
    config = resolve_config(opts)

    if config.enabled do
      request = build_request(surface, :post, url, metadata)

      with :ok <- validate_redirect(request, response, config),
           :ok <- validate_content_length(request, response, config),
           :ok <- validate_mime_type(request, response, config),
           :ok <- validate_body_size(request, response, config) do
        emit(:allow, request, nil, config)
        :ok
      else
        {:error, detail} ->
          emit(:deny, request, detail, config)
          {:error, {:egress_blocked, detail}}
      end
    else
      :ok
    end
  end

  def validate_stream_headers(surface, url, headers, opts \\ [], metadata \\ %{})
      when surface in @surfaces and is_list(opts) do
    validate_stream_response(surface, url, 200, headers, opts, metadata)
  end

  def validate_stream_response(surface, url, status, headers, opts \\ [], metadata \\ %{})
      when surface in @surfaces and is_integer(status) and is_list(opts) do
    config = resolve_config(opts)

    if config.enabled do
      response = %Finch.Response{status: status, headers: headers, body: ""}
      validate_response(surface, url, response, opts, metadata)
    else
      :ok
    end
  end

  def validate_stream_body_size(surface, url, bytes, opts \\ [], metadata \\ %{})
      when surface in @surfaces and is_integer(bytes) and bytes >= 0 and is_list(opts) do
    config = resolve_config(opts)

    if config.enabled do
      request = build_request(surface, :post, url, metadata)
      max_response_bytes = effective_surface_config(surface, config).max_response_bytes

      if is_integer(max_response_bytes) and bytes > max_response_bytes do
        {:error, detail} =
          error(
            request,
            :response_too_large,
            "Outbound #{surface} response body exceeds the configured byte cap.",
            %{bytes: bytes, max_response_bytes: max_response_bytes}
          )

        emit(:deny, request, detail, config)
        {:error, {:egress_blocked, detail}}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp build_request(surface, method, url, metadata) do
    uri = URI.parse(to_string(url))

    %{
      surface: surface,
      method: normalize_method(method),
      url: safe_url(uri),
      raw_url: to_string(url),
      host: normalize_host(uri.host),
      scheme: normalize_scheme(uri.scheme),
      metadata: metadata
    }
  end

  defp validate_method(request, config) do
    allowed_methods =
      request.surface
      |> effective_surface_config(config)
      |> Map.get(:allow_methods, [])
      |> Enum.map(&normalize_method/1)

    if allowed_methods == [] or request.method in allowed_methods do
      :ok
    else
      error(
        request,
        :method_not_allowed,
        "Outbound #{request.surface} requests may not use #{inspect(request.method)}.",
        %{allowed_methods: allowed_methods}
      )
    end
  end

  defp validate_url(request, config) do
    uri = URI.parse(request.raw_url)

    if is_binary(uri.scheme) and is_binary(uri.host) and uri.host != "" do
      {:ok, uri}
    else
      error(
        request,
        :invalid_url,
        "Outbound #{request.surface} request URL is missing a valid scheme or host.",
        %{url: request.url, config_enabled: config.enabled}
      )
    end
  end

  defp validate_scheme(request, %URI{} = uri, config) do
    allow_schemes =
      request.surface
      |> effective_surface_config(config)
      |> Map.get(:allow_schemes, @default_allow_schemes)
      |> Enum.map(&normalize_scheme/1)

    if normalize_scheme(uri.scheme) in allow_schemes do
      :ok
    else
      error(
        request,
        :scheme_not_allowed,
        "Outbound #{request.surface} requests may not use scheme #{inspect(uri.scheme)}.",
        %{allowed_schemes: allow_schemes, url: request.url}
      )
    end
  end

  defp validate_host(request, %URI{} = uri, config) do
    surface_config = effective_surface_config(request.surface, config)
    host = normalize_host(uri.host)

    cond do
      host in [nil, ""] ->
        error(request, :invalid_host, "Outbound request host is empty.", %{url: request.url})

      deny_match?(host, Map.get(surface_config, :deny_hosts, [])) ->
        error(
          request,
          :host_denied,
          "Outbound #{request.surface} request host #{inspect(host)} is explicitly denied.",
          %{host: host}
        )

      localhost?(host) and not Map.get(surface_config, :allow_localhost, false) ->
        error(
          request,
          :localhost_blocked,
          "Outbound #{request.surface} request to localhost is blocked by default.",
          %{host: host}
        )

      private_network?(host) and not Map.get(surface_config, :allow_private_network, false) ->
        error(
          request,
          :private_network_blocked,
          "Outbound #{request.surface} request to a private-network host is blocked by default.",
          %{host: host}
        )

      allowed_hosts?(Map.get(surface_config, :allow_hosts, []), host) ->
        validate_resolved_host(request, host, surface_config)

      true ->
        error(
          request,
          :host_not_allowlisted,
          "Outbound #{request.surface} request host #{inspect(host)} is not in the allowlist.",
          %{host: host, allow_hosts: Map.get(surface_config, :allow_hosts, [])}
        )
    end
  end

  defp validate_userinfo(_request, %URI{userinfo: nil}, _config), do: :ok

  defp validate_userinfo(request, %URI{userinfo: _userinfo}, config) do
    if get_in(config, [:surfaces, request.surface, :allow_userinfo]) do
      :ok
    else
      error(
        request,
        :userinfo_not_allowed,
        "Outbound #{request.surface} URLs may not embed credentials or other userinfo.",
        %{url: request.url}
      )
    end
  end

  defp validate_redirect(request, %Finch.Response{status: status, headers: headers}, config) do
    max_redirects =
      request.surface
      |> effective_surface_config(config)
      |> Map.get(:max_redirects, 0)

    if status in 300..399 and max_redirects == 0 do
      error(
        request,
        :redirect_blocked,
        "Outbound #{request.surface} redirects are blocked by policy.",
        %{status: status, location: response_header(headers, "location")}
      )
    else
      :ok
    end
  end

  defp validate_content_length(request, %Finch.Response{headers: headers}, config) do
    max_content_length =
      request.surface
      |> effective_surface_config(config)
      |> Map.get(:max_content_length)

    case {max_content_length, response_header(headers, "content-length")} do
      {limit, value} when is_integer(limit) and is_binary(value) ->
        with {size, ""} <- Integer.parse(value),
             true <- size <= limit do
          :ok
        else
          _ ->
            error(
              request,
              :content_length_exceeded,
              "Outbound #{request.surface} response declared a content length above the configured cap.",
              %{content_length: value, max_content_length: limit}
            )
        end

      _ ->
        :ok
    end
  end

  defp validate_mime_type(request, %Finch.Response{headers: headers}, config) do
    allowed_mime_types =
      request.surface
      |> effective_surface_config(config)
      |> Map.get(:allowed_mime_types, [])
      |> Enum.map(&normalize_mime/1)

    case normalize_mime(response_header(headers, "content-type")) do
      nil ->
        :ok

      mime ->
        if allowed_mime_types == [] or mime in allowed_mime_types do
          :ok
        else
          error(
            request,
            :mime_not_allowed,
            "Outbound #{request.surface} response MIME type #{inspect(mime)} is not allowed.",
            %{mime: mime, allowed_mime_types: allowed_mime_types}
          )
        end
    end
  end

  defp validate_body_size(request, %Finch.Response{body: body}, config) when is_binary(body) do
    max_response_bytes =
      request.surface
      |> effective_surface_config(config)
      |> Map.get(:max_response_bytes)

    if is_integer(max_response_bytes) and byte_size(body) > max_response_bytes do
      error(
        request,
        :response_too_large,
        "Outbound #{request.surface} response body exceeds the configured byte cap.",
        %{bytes: byte_size(body), max_response_bytes: max_response_bytes}
      )
    else
      :ok
    end
  end

  defp validate_body_size(_request, _response, _config), do: :ok

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:egress)
      |> normalize_config()

    merge_config(global, per_call)
  end

  defp normalize_config(nil), do: %{}
  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}

  defp normalize_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "egress config must be a keyword list, map, boolean, or nil, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    surface_entries =
      @surfaces
      |> Enum.map(fn surface ->
        {surface,
         normalize_surface_config(
           fetch_value(config, surface) ||
             get_in(fetch_value(config, :surfaces) || %{}, [surface])
         )}
      end)
      |> Enum.reject(fn {_surface, value} -> value == nil end)
      |> Enum.into(%{})

    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      emit_telemetry: normalize_booleanish(fetch_value(config, :emit_telemetry)),
      return_metadata: normalize_booleanish(fetch_value(config, :return_metadata)),
      surfaces: if(surface_entries == %{}, do: nil, else: surface_entries)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "egress config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp normalize_surface_config(nil), do: nil

  defp normalize_surface_config(config) when is_list(config) do
    config
    |> Enum.into(%{})
    |> normalize_surface_config()
  end

  defp normalize_surface_config(%{} = config) do
    %{
      allow_hosts: normalize_hosts(fetch_value(config, :allow_hosts)),
      deny_hosts: normalize_hosts(fetch_value(config, :deny_hosts)),
      allow_schemes: normalize_schemes(fetch_value(config, :allow_schemes)),
      allow_methods: normalize_methods(fetch_value(config, :allow_methods)),
      allow_private_network: normalize_booleanish(fetch_value(config, :allow_private_network)),
      allow_localhost: normalize_booleanish(fetch_value(config, :allow_localhost)),
      allow_userinfo: normalize_booleanish(fetch_value(config, :allow_userinfo)),
      resolve_dns: normalize_booleanish(fetch_value(config, :resolve_dns)),
      dns_resolver: normalize_dns_resolver(fetch_value(config, :dns_resolver)),
      max_response_bytes: normalize_positive_integer(fetch_value(config, :max_response_bytes)),
      max_content_length: normalize_positive_integer(fetch_value(config, :max_content_length)),
      max_redirects: normalize_non_negative_integer(fetch_value(config, :max_redirects)),
      allowed_mime_types: normalize_mime_types(fetch_value(config, :allowed_mime_types))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_surface_config(other) do
    raise ArgumentError,
          "egress surface config must be a keyword list, map, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    surfaces =
      @surfaces
      |> Enum.reduce(@default_config.surfaces, fn surface, acc ->
        Map.put(
          acc,
          surface,
          @default_surface_config
          |> Map.merge(Map.get(@default_config.surfaces, surface, %{}))
          |> Map.merge(get_in(global, [:surfaces, surface]) || %{})
          |> Map.merge(get_in(per_call, [:surfaces, surface]) || %{})
        )
      end)

    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(:surfaces, surfaces)
  end

  defp effective_surface_config(surface, %{surfaces: surfaces}) do
    Map.get(surfaces, surface, @default_surface_config)
  end

  defp effective_surface_config(surface, config),
    do: effective_surface_config(surface, %{surfaces: config.surfaces})

  defp emit(decision, request, detail, %{emit_telemetry: true}) do
    :telemetry.execute(
      [:synaptic, :egress, :decision],
      %{count: 1},
      %{
        decision: decision,
        surface: request.surface,
        method: request.method,
        host: request.host,
        scheme: request.scheme,
        code: detail && detail.code
      }
    )
  end

  defp emit(_decision, _request, _detail, _config), do: :ok

  defp error(request, code, message, details) do
    {:error,
     %{
       surface: request.surface,
       code: code,
       message: message,
       details: Map.put(details, :url, request.url),
       suggestions: suggestions(code, request)
     }}
  end

  defp suggestions(:host_not_allowlisted, request) do
    [
      "Add #{inspect(request.host)} to `egress: [#{request.surface}: [allow_hosts: [...]]]`.",
      "Use `Synaptic.explain_security/2` to confirm the effective posture before retrying."
    ]
  end

  defp suggestions(:localhost_blocked, _request) do
    [
      "Set `allow_localhost: true` only for controlled local development.",
      "Prefer a managed remote endpoint in higher-assurance environments."
    ]
  end

  defp suggestions(:private_network_blocked, _request) do
    [
      "Allow private-network access explicitly only when the target is trusted and isolated.",
      "Review the target host for SSRF risk before opening the allowlist."
    ]
  end

  defp suggestions(:mime_not_allowed, request) do
    [
      "Add the required MIME type to `egress: [#{request.surface}: [allowed_mime_types: [...]]]`.",
      "If the endpoint should return JSON, verify that the upstream service is configured correctly."
    ]
  end

  defp suggestions(:response_too_large, _request) do
    [
      "Raise `max_response_bytes` only if the caller truly needs the larger payload.",
      "Prefer pagination, previews, or spill-to-handle patterns for large responses."
    ]
  end

  defp suggestions(:content_length_exceeded, _request) do
    [
      "Raise `max_content_length` only after confirming the endpoint is expected to return larger payloads.",
      "Consider using a smaller or paginated endpoint instead."
    ]
  end

  defp suggestions(:scheme_not_allowed, _request) do
    [
      "Use HTTPS for outbound calls whenever possible.",
      "If HTTP is unavoidable in local development, scope the exception to a narrow allowlist."
    ]
  end

  defp suggestions(:userinfo_not_allowed, _request) do
    [
      "Move credentials out of the URL and into a brokered or runtime-generated header.",
      "Avoid embedding secrets in config, logs, or prompts."
    ]
  end

  defp suggestions(_code, _request), do: []

  defp allowed_hosts?([], _host), do: false
  defp allowed_hosts?(hosts, host), do: Enum.any?(hosts, &host_match?(host, &1))

  defp deny_match?(host, hosts), do: Enum.any?(hosts, &host_match?(host, &1))

  defp host_match?(host, "*." <> suffix) do
    normalized_suffix = String.downcase(suffix)
    host == normalized_suffix or String.ends_with?(host, "." <> normalized_suffix)
  end

  defp host_match?(host, pattern), do: host == normalize_host(pattern)

  defp localhost?(host) when is_binary(host) do
    host in ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"] or
      String.ends_with?(host, ".localhost")
  end

  defp private_network?(host) when is_binary(host) do
    case parse_ip(host) do
      {:ok, address} -> private_address?(address)
      _ -> false
    end
  end

  defp validate_resolved_host(_request, _host, %{allow_private_network: true}), do: :ok
  defp validate_resolved_host(_request, host, _config) when host in [nil, ""], do: :ok

  defp validate_resolved_host(request, host, config) do
    if localhost?(host) and Map.get(config, :allow_localhost, false) do
      :ok
    else
      validate_resolved_non_local_host(request, host, config)
    end
  end

  defp validate_resolved_non_local_host(request, host, config) do
    if Map.get(config, :resolve_dns, true) and match?({:error, _}, parse_ip(host)) do
      case resolve_addresses(host, Map.get(config, :dns_resolver)) do
        {:ok, addresses} when is_list(addresses) and addresses != [] ->
          if Enum.all?(addresses, &valid_address?/1) do
            validate_public_addresses(request, host, addresses)
          else
            resolution_error(request, host, :invalid_resolver_result)
          end

        {:ok, _addresses} ->
          resolution_error(request, host, :empty_resolver_result)

        {:error, reason} ->
          resolution_error(request, host, reason)

        other ->
          resolution_error(request, host, {:invalid_resolver_result, other})
      end
    else
      :ok
    end
  end

  defp validate_public_addresses(request, host, addresses) do
    if Enum.any?(addresses, &private_address?/1) do
      error(
        request,
        :private_network_blocked,
        "Outbound #{request.surface} hostname resolves to a private-network address.",
        %{host: host}
      )
    else
      :ok
    end
  end

  defp resolution_error(request, host, reason) do
    error(
      request,
      :host_resolution_failed,
      "Outbound #{request.surface} hostname could not be resolved safely.",
      %{host: host, reason: inspect(reason)}
    )
  end

  defp resolve_addresses(host, resolver) when is_function(resolver, 1) do
    resolver.(host)
  rescue
    error -> {:error, {:resolver_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:resolver_throw, kind, reason}}
  end

  defp resolve_addresses(host, _resolver) do
    host = to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(host, family) do
          {:ok, values} -> values
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
  end

  defp private_address?({0, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({100, second, _, _}) when second in 64..127, do: true
  defp private_address?({127, _, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({172, second, _, _}) when second in 16..31, do: true
  defp private_address?({192, 0, 0, _}), do: true
  defp private_address?({192, 0, 2, _}), do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({198, second, _, _}) when second in [18, 19, 51], do: true
  defp private_address?({203, 0, 113, _}), do: true
  defp private_address?({first, _, _, _}) when first >= 224, do: true
  defp private_address?(tuple) when tuple_size(tuple) == 8, do: private_ipv6?(tuple)
  defp private_address?(_address), do: false

  defp valid_address?(tuple) when is_tuple(tuple) and tuple_size(tuple) == 4 do
    tuple
    |> Tuple.to_list()
    |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= 255))
  end

  defp valid_address?(tuple) when is_tuple(tuple) and tuple_size(tuple) == 8 do
    tuple
    |> Tuple.to_list()
    |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= 65_535))
  end

  defp valid_address?(_address), do: false

  defp private_ipv6?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ipv6?({65152, _, _, _, _, _, _, _}), do: true
  defp private_ipv6?({65153, _, _, _, _, _, _, _}), do: true
  defp private_ipv6?({65280, _, _, _, _, _, _, _}), do: true

  defp private_ipv6?(tuple) do
    first = elem(tuple, 0)
    second = elem(tuple, 1)

    (first &&& 0xFE00) == 0xFC00 or
      (first &&& 0xFFC0) == 0xFE80 or
      (first &&& 0xFF00) == 0xFF00 or
      (first == 0x2001 and second == 0x0DB8)
  end

  defp parse_ip(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> to_charlist()
    |> :inet.parse_address()
  end

  defp response_header(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp safe_url(%URI{} = uri) do
    %URI{uri | userinfo: nil, query: nil, fragment: nil}
    |> URI.to_string()
  end

  defp safe_url(_), do: nil

  defp normalize_host(nil), do: nil

  defp normalize_host(host) do
    host
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_scheme(nil), do: nil
  defp normalize_scheme(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp normalize_method(value) when is_atom(value), do: value

  defp normalize_method(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :unknown
  end

  defp normalize_hosts(nil), do: nil
  defp normalize_hosts(values) when is_list(values), do: Enum.map(values, &normalize_host/1)
  defp normalize_hosts(value), do: [normalize_host(value)]

  defp normalize_schemes(nil), do: nil
  defp normalize_schemes(values) when is_list(values), do: Enum.map(values, &normalize_scheme/1)
  defp normalize_schemes(value), do: [normalize_scheme(value)]

  defp normalize_methods(nil), do: nil

  defp normalize_methods(values) when is_list(values) do
    Enum.map(values, fn value ->
      method = normalize_method(value)

      unless method in @methods do
        raise ArgumentError,
              "egress allow_methods must contain HTTP method atoms/strings, got: #{inspect(value)}"
      end

      method
    end)
  end

  defp normalize_methods(value), do: normalize_methods([value])

  defp normalize_mime_types(nil), do: nil
  defp normalize_mime_types(values) when is_list(values), do: Enum.map(values, &normalize_mime/1)
  defp normalize_mime_types(value), do: [normalize_mime(value)]

  defp normalize_mime(nil), do: nil

  defp normalize_mime(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp normalize_booleanish(nil), do: nil
  defp normalize_booleanish(value) when is_boolean(value), do: value
  defp normalize_booleanish("true"), do: true
  defp normalize_booleanish("false"), do: false
  defp normalize_booleanish(_value), do: nil

  defp normalize_dns_resolver(nil), do: nil
  defp normalize_dns_resolver(value) when is_function(value, 1), do: value

  defp normalize_dns_resolver(value) do
    raise ArgumentError,
          "egress dns_resolver must be a one-argument function, got: #{inspect(value)}"
  end

  defp normalize_positive_integer(nil), do: nil
  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value), do: nil

  defp normalize_non_negative_integer(nil), do: nil
  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_integer(_value), do: nil

  defp fetch_value(config, key) do
    Map.get(config, key) || Map.get(config, to_string(key))
  end
end
