defmodule Synaptic.RuntimeSecurity do
  @moduledoc false

  alias Synaptic.Redaction

  @default_config %{
    enabled: false,
    redaction: %{
      types: [:email, :phone, :ssn, :payment_card, :auth_token]
    },
    history: %{
      redact: true,
      max_entries: nil
    },
    events: %{
      redact: true
    },
    snapshot: %{
      redact: false
    },
    retention: %{
      shutdown_after_ms: nil,
      purge_context_on_terminal: false
    }
  }

  def new(opts \\ []) when is_list(opts) do
    %{config: resolve_config(opts)}
  end

  def enabled?(%{config: %{enabled: true}}), do: true
  def enabled?(_state), do: false

  def sanitize_history_entry(entry, %{} = state) when is_map(entry) do
    if enabled?(state) and get_in(state, [:config, :history, :redact]) do
      redact_term(entry, state.config)
    else
      entry
    end
  end

  def sanitize_event(event, %{} = state) when is_map(event) do
    if enabled?(state) and get_in(state, [:config, :events, :redact]) do
      redact_term(event, state.config)
    else
      event
    end
  end

  def sanitize_snapshot(snapshot, %{} = state) when is_map(snapshot) do
    if enabled?(state) and get_in(state, [:config, :snapshot, :redact]) do
      redact_term(snapshot, state.config)
    else
      snapshot
    end
  end

  def trim_history(history, %{} = state) when is_list(history) do
    max_entries = get_in(state, [:config, :history, :max_entries])

    if enabled?(state) and is_integer(max_entries) and max_entries > 0 do
      Enum.take(history, max_entries)
    else
      history
    end
  end

  def terminal_cleanup(runtime_state, %{} = state) when is_map(runtime_state) do
    if enabled?(state) and get_in(state, [:config, :retention, :purge_context_on_terminal]) do
      runtime_state
      |> Map.put(:context, %{})
      |> Map.put(:waiting, nil)
      |> Map.update(:last_error, nil, &redact_term(&1, state.config))
    else
      runtime_state
    end
  end

  def shutdown_after_ms(%{} = state, default_ms) do
    if enabled?(state) do
      get_in(state, [:config, :retention, :shutdown_after_ms]) || default_ms
    else
      default_ms
    end
  end

  defp redact_term(term, config) do
    types = get_in(config, [:redaction, :types]) || []
    Redaction.scrub(term, types: types)
  end

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:runtime_security)
      |> normalize_config()

    merge_config(global, per_call)
  end

  defp normalize_config(nil), do: %{}
  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}

  defp normalize_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "runtime security config must be a keyword list, map, boolean, or nil, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      redaction: normalize_redaction_config(fetch_value(config, :redaction)),
      history: normalize_history_config(fetch_value(config, :history)),
      events: normalize_events_config(fetch_value(config, :events)),
      snapshot: normalize_snapshot_config(fetch_value(config, :snapshot)),
      retention: normalize_retention_config(fetch_value(config, :retention))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "runtime security config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(
      :redaction,
      @default_config.redaction
      |> Map.merge(Map.get(global, :redaction, %{}))
      |> Map.merge(Map.get(per_call, :redaction, %{}))
    )
    |> Map.put(
      :history,
      @default_config.history
      |> Map.merge(Map.get(global, :history, %{}))
      |> Map.merge(Map.get(per_call, :history, %{}))
    )
    |> Map.put(
      :events,
      @default_config.events
      |> Map.merge(Map.get(global, :events, %{}))
      |> Map.merge(Map.get(per_call, :events, %{}))
    )
    |> Map.put(
      :snapshot,
      @default_config.snapshot
      |> Map.merge(Map.get(global, :snapshot, %{}))
      |> Map.merge(Map.get(per_call, :snapshot, %{}))
    )
    |> Map.put(
      :retention,
      @default_config.retention
      |> Map.merge(Map.get(global, :retention, %{}))
      |> Map.merge(Map.get(per_call, :retention, %{}))
    )
  end

  defp normalize_redaction_config(nil), do: nil

  defp normalize_redaction_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_redaction_config()
  end

  defp normalize_redaction_config(%{} = config) do
    %{
      types: normalize_types(fetch_value(config, :types))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_redaction_config(_other), do: nil

  defp normalize_history_config(nil), do: nil

  defp normalize_history_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_history_config()
  end

  defp normalize_history_config(%{} = config) do
    %{
      redact: normalize_booleanish(fetch_value(config, :redact)),
      max_entries: normalize_positive_integer(fetch_value(config, :max_entries))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_history_config(_other), do: nil

  defp normalize_events_config(nil), do: nil

  defp normalize_events_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_events_config()
  end

  defp normalize_events_config(%{} = config) do
    %{
      redact: normalize_booleanish(fetch_value(config, :redact))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_events_config(_other), do: nil

  defp normalize_snapshot_config(nil), do: nil

  defp normalize_snapshot_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_snapshot_config()
  end

  defp normalize_snapshot_config(%{} = config) do
    %{
      redact: normalize_booleanish(fetch_value(config, :redact))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_snapshot_config(_other), do: nil

  defp normalize_retention_config(nil), do: nil

  defp normalize_retention_config(config) when is_list(config) do
    config |> Enum.into(%{}) |> normalize_retention_config()
  end

  defp normalize_retention_config(%{} = config) do
    %{
      shutdown_after_ms: normalize_positive_integer(fetch_value(config, :shutdown_after_ms)),
      purge_context_on_terminal:
        normalize_booleanish(fetch_value(config, :purge_context_on_terminal))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_retention_config(_other), do: nil

  defp normalize_types(nil), do: nil
  defp normalize_types(values) when is_list(values), do: Enum.map(values, &normalize_type/1)
  defp normalize_types(value), do: [normalize_type(value)]

  defp normalize_type(value) when value in [:email, :phone, :ssn, :payment_card, :auth_token],
    do: value

  defp normalize_type(value) when is_binary(value) do
    case String.downcase(value) do
      "email" -> :email
      "phone" -> :phone
      "ssn" -> :ssn
      "payment_card" -> :payment_card
      "auth_token" -> :auth_token
      _ -> nil
    end
  end

  defp normalize_type(_value), do: nil

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

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
