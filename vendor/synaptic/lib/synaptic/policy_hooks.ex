defmodule Synaptic.PolicyHooks do
  @moduledoc false

  @surfaces [:pre_prompt, :post_output, :pre_tool, :post_tool, :pre_mcp]
  @hook_failures [:open, :closed]

  @default_failure_policy %{
    pre_prompt: :open,
    post_output: :open,
    pre_tool: :closed,
    post_tool: :open,
    pre_mcp: :closed
  }

  @default_config %{
    enabled: false,
    managed_only: false,
    emit_telemetry: true,
    failure_policy: @default_failure_policy,
    pre_prompt: [],
    post_output: [],
    pre_tool: [],
    post_tool: [],
    pre_mcp: []
  }

  def new(opts \\ []) when is_list(opts) do
    resolve_config(opts)
  end

  def enabled?(%{enabled: true}), do: true
  def enabled?(_config), do: false

  def run(surface, payload, config) when surface in @surfaces and is_map(payload) do
    hooks = Map.get(config, surface, [])

    if enabled?(config) and hooks != [] do
      Enum.reduce_while(hooks, {:ok, payload}, fn hook, {:ok, current_payload} ->
        case invoke_hook(hook, current_payload) do
          :ok ->
            maybe_emit(surface, :ok, hook, config)
            {:cont, {:ok, current_payload}}

          {:ok, %{} = updated_payload} ->
            maybe_emit(surface, :ok, hook, config)
            {:cont, {:ok, updated_payload}}

          {:continue, %{} = updated_payload} ->
            maybe_emit(surface, :ok, hook, config)
            {:cont, {:ok, updated_payload}}

          {:deny, reason} ->
            maybe_emit(surface, :deny, hook, config)
            {:halt, {:error, {:hook_denied, surface, normalize_reason(reason)}}}

          {:error, reason} ->
            handle_failure(surface, hook, reason, current_payload, config)

          other ->
            handle_failure(surface, hook, {:invalid_hook_return, other}, current_payload, config)
        end
      end)
    else
      {:ok, payload}
    end
  end

  defp handle_failure(surface, hook, reason, payload, config) do
    maybe_emit(surface, :error, hook, config)

    case failure_mode(config, surface) do
      :open ->
        {:cont, {:ok, payload}}

      :closed ->
        {:halt, {:error, {:hook_failure, surface, normalize_reason(reason)}}}
    end
  end

  defp invoke_hook(hook, payload) when is_function(hook, 1), do: hook.(payload)

  defp invoke_hook({mod, fun}, payload) when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [payload])
  end

  defp invoke_hook({mod, fun, extra_args}, payload)
       when is_atom(mod) and is_atom(fun) and is_list(extra_args) do
    apply(mod, fun, [payload | extra_args])
  end

  defp invoke_hook(other, _payload), do: {:error, {:invalid_hook, other}}

  defp failure_mode(config, surface) do
    config
    |> Map.get(:failure_policy, @default_failure_policy)
    |> Map.get(surface, Map.fetch!(@default_failure_policy, surface))
  end

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:hooks)
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
      raise ArgumentError, "hook config must be a keyword list, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      managed_only: normalize_booleanish(fetch_value(config, :managed_only)),
      emit_telemetry: normalize_booleanish(fetch_value(config, :emit_telemetry)),
      failure_policy: normalize_failure_policy(fetch_value(config, :failure_policy)),
      pre_prompt: normalize_hooks(fetch_value(config, :pre_prompt)),
      post_output: normalize_hooks(fetch_value(config, :post_output)),
      pre_tool: normalize_hooks(fetch_value(config, :pre_tool)),
      post_tool: normalize_hooks(fetch_value(config, :post_tool)),
      pre_mcp: normalize_hooks(fetch_value(config, :pre_mcp))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "hook config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp normalize_hooks(nil), do: nil
  defp normalize_hooks(hooks) when is_list(hooks), do: hooks
  defp normalize_hooks(hook), do: [hook]

  defp normalize_failure_policy(nil), do: nil

  defp normalize_failure_policy(policy) when is_list(policy) do
    unless Keyword.keyword?(policy) do
      raise ArgumentError,
            "hook failure_policy must be a keyword list or map, got: #{inspect(policy)}"
    end

    policy
    |> Enum.into(%{})
    |> normalize_failure_policy()
  end

  defp normalize_failure_policy(%{} = policy) do
    normalized =
      Enum.reduce(policy, %{}, fn {surface, mode}, acc ->
        normalized_surface = normalize_surface(surface)
        normalized_mode = normalize_failure_mode(mode)

        if normalized_surface in @surfaces and normalized_mode in @hook_failures do
          Map.put(acc, normalized_surface, normalized_mode)
        else
          acc
        end
      end)

    if normalized == %{}, do: nil, else: normalized
  end

  defp normalize_failure_policy(_other), do: nil

  defp merge_config(global, per_call) do
    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(
      :failure_policy,
      @default_failure_policy
      |> Map.merge(Map.get(global, :failure_policy, %{}))
      |> Map.merge(Map.get(per_call, :failure_policy, %{}))
    )
    |> merge_hook_surface(:pre_prompt, global, per_call)
    |> merge_hook_surface(:post_output, global, per_call)
    |> merge_hook_surface(:pre_tool, global, per_call)
    |> merge_hook_surface(:post_tool, global, per_call)
    |> merge_hook_surface(:pre_mcp, global, per_call)
  end

  defp merge_hook_surface(config, surface, global, per_call) do
    global_hooks = Map.get(global, surface, [])
    per_call_hooks = Map.get(per_call, surface, [])
    Map.put(config, surface, global_hooks ++ per_call_hooks)
  end

  defp normalize_booleanish(nil), do: nil
  defp normalize_booleanish(value) when value in [true, false], do: value
  defp normalize_booleanish("true"), do: true
  defp normalize_booleanish("false"), do: false
  defp normalize_booleanish(_value), do: nil

  defp normalize_surface(value) when value in @surfaces, do: value

  defp normalize_surface(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    _ -> nil
  end

  defp normalize_surface(_value), do: nil

  defp normalize_failure_mode(value) when value in @hook_failures, do: value
  defp normalize_failure_mode("open"), do: :open
  defp normalize_failure_mode("closed"), do: :closed
  defp normalize_failure_mode(_value), do: nil

  defp maybe_emit(surface, status, hook, %{emit_telemetry: true}) do
    :telemetry.execute(
      [:synaptic, :hooks, surface],
      %{count: 1},
      %{status: status, hook: inspect(hook)}
    )
  end

  defp maybe_emit(_surface, _status, _hook, _config), do: :ok

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
