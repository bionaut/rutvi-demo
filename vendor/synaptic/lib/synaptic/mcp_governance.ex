defmodule Synaptic.MCPGovernance do
  @moduledoc false

  alias Synaptic.MCP.Connection

  @default_config %{
    enabled: false,
    managed_only: false,
    allow_servers: nil,
    deny_servers: [],
    allow_url_patterns: nil,
    deny_url_patterns: [],
    allow_command_patterns: nil,
    deny_command_patterns: []
  }

  def config(opts \\ []) when is_list(opts) do
    resolve_config(opts)
  end

  def authorize_connections(connections, opts \\ []) when is_list(connections) do
    config = resolve_config(opts)

    if config.enabled do
      Enum.reduce_while(connections, {:ok, []}, fn connection, {:ok, acc} ->
        case authorize_connection(connection, config) do
          :allow -> {:cont, {:ok, acc ++ [connection]}}
          {:deny, reason} -> {:halt, {:error, {:mcp_governance_denied, connection.name, reason}}}
        end
      end)
    else
      {:ok, connections}
    end
  end

  defp authorize_connection(%Connection{} = connection, config) do
    cond do
      config.managed_only and not managed?(connection) ->
        {:deny, :unmanaged_server}

      blocked_name?(connection, config) ->
        {:deny, :server_name_blocked}

      blocked_url?(connection, config) ->
        {:deny, :server_url_blocked}

      blocked_command?(connection, config) ->
        {:deny, :server_command_blocked}

      true ->
        :allow
    end
  end

  defp blocked_name?(connection, config) do
    name = connection.name

    denied?(name, config.deny_servers) or not allowed?(name, config.allow_servers)
  end

  defp blocked_url?(connection, config) do
    url = endpoint(connection)

    denied?(url, config.deny_url_patterns) or not allowed?(url, config.allow_url_patterns)
  end

  defp blocked_command?(connection, config) do
    command =
      connection.adapter_opts
      |> Keyword.get(:command)
      |> case do
        nil -> Keyword.get(connection.adapter_opts, :command)
        value -> value
      end

    denied?(command, config.deny_command_patterns) or
      not allowed?(command, config.allow_command_patterns)
  end

  defp denied?(_value, []), do: false
  defp denied?(nil, _patterns), do: false

  defp denied?(value, patterns) do
    Enum.any?(patterns, &matches?(&1, value))
  end

  defp allowed?(_value, nil), do: true
  defp allowed?(nil, _patterns), do: false
  defp allowed?(_value, []), do: false

  defp allowed?(value, patterns) do
    Enum.any?(patterns, &matches?(&1, value))
  end

  defp matches?(%Regex{} = regex, value), do: Regex.match?(regex, to_string(value))

  defp matches?(pattern, value) when is_binary(pattern),
    do: String.contains?(to_string(value), pattern)

  defp matches?(pattern, value) when is_atom(pattern),
    do: to_string(value) == Atom.to_string(pattern)

  defp matches?(pattern, value), do: to_string(value) == to_string(pattern)

  defp managed?(%Connection{} = connection) do
    metadata = connection.metadata || %{}
    Map.get(metadata, :managed, false) || Map.get(metadata, "managed", false)
  end

  defp endpoint(%Connection{} = connection) do
    Keyword.get(connection.adapter_opts, :base_url) ||
      Keyword.get(connection.adapter_opts, :endpoint) ||
      ""
  end

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:mcp_governance)
      |> normalize_config()

    if Map.get(global, :managed_only, false) do
      merge_config(%{}, global)
    else
      merge_config(global, per_call)
    end
  end

  defp normalize_config(nil), do: %{}
  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}

  defp normalize_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError, "MCP governance config must be a keyword list, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      managed_only: normalize_booleanish(fetch_value(config, :managed_only)),
      allow_servers: normalize_patterns(fetch_value(config, :allow_servers)),
      deny_servers: normalize_patterns(fetch_value(config, :deny_servers)),
      allow_url_patterns: normalize_patterns(fetch_value(config, :allow_url_patterns)),
      deny_url_patterns: normalize_patterns(fetch_value(config, :deny_url_patterns)),
      allow_command_patterns: normalize_patterns(fetch_value(config, :allow_command_patterns)),
      deny_command_patterns: normalize_patterns(fetch_value(config, :deny_command_patterns))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "MCP governance config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
  end

  defp normalize_patterns(nil), do: nil
  defp normalize_patterns(patterns) when is_list(patterns), do: patterns
  defp normalize_patterns(pattern), do: [pattern]

  defp normalize_booleanish(nil), do: nil
  defp normalize_booleanish(value) when value in [true, false], do: value
  defp normalize_booleanish("true"), do: true
  defp normalize_booleanish("false"), do: false
  defp normalize_booleanish(_value), do: nil

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
