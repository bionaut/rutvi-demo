defmodule Synaptic.Audit do
  @moduledoc false

  alias Synaptic.{AuditStore, Redaction}

  @allowed_metadata_keys [
    :agent,
    :async,
    :blocked,
    :category,
    :compacted_tool_messages,
    :current_step,
    :decision,
    :detection_count,
    :detection_types,
    :event,
    :evidence_count,
    :factuality_action,
    :hook_surface,
    :issue_codes,
    :issue_count,
    :managed_only,
    :mcp_count,
    :message_count,
    :model,
    :question_count,
    :policy_decision_count,
    :provenance,
    :reason,
    :record_count,
    :run_id,
    :server,
    :source,
    :spill_count,
    :static_count,
    :status,
    :step,
    :step_name,
    :stream,
    :supported,
    :sensitivity_levels,
    :target,
    :tenant,
    :tool,
    :tool_count,
    :validation_surface,
    :workflow
  ]

  @default_config %{
    enabled: false,
    return_metadata: false,
    emit_telemetry: true,
    retention_ms: 7 * 24 * 60 * 60 * 1000,
    categories: %{
      judgment: true,
      chat: true,
      tool: true,
      workflow: true,
      guardrail: true
    }
  }

  @type state :: %{
          config: map(),
          audit_id: String.t() | nil,
          run_id: String.t() | nil,
          workflow: module() | nil,
          step_name: atom() | nil,
          tenant: String.t() | nil,
          record_count: non_neg_integer()
        }

  def new(opts \\ []) when is_list(opts) do
    config = resolve_config(opts)
    run_id = Keyword.get(opts, :run_id) || get_from_context(:__run_id__)
    step_name = Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    workflow = Keyword.get(opts, :workflow)
    tenant = Keyword.get(opts, :tenant) || get_from_context(:__tenant__)

    %{
      config: config,
      audit_id: if(config.enabled, do: run_id || generate_audit_id(), else: nil),
      run_id: run_id,
      workflow: workflow,
      step_name: step_name,
      tenant: tenant,
      record_count: 0
    }
  end

  def enabled?(%{config: %{enabled: true}}), do: true
  def enabled?(_state), do: false

  def record(category, event, metadata, %{} = state)
      when is_atom(category) and is_map(metadata) do
    if enabled?(state) and category_enabled?(state.config, category) do
      sanitized =
        metadata
        |> Map.merge(base_metadata(state))
        |> Map.put(:category, category)
        |> Map.put(:event, event)
        |> sanitize_metadata()

      _entry =
        AuditStore.put(
          state.audit_id,
          state.run_id,
          category,
          event,
          sanitized,
          state.config.retention_ms
        )

      maybe_emit(sanitized, state.config)
      %{state | record_count: state.record_count + 1}
    else
      state
    end
  end

  def finalize_result({:ok, content}, %{} = state) do
    maybe_attach_metadata({:ok, content}, state)
  end

  def finalize_result({:ok, content, meta}, %{} = state) when is_map(meta) do
    maybe_attach_metadata({:ok, content, meta}, state)
  end

  def finalize_result(other, _state), do: other

  def records(audit_id) when is_binary(audit_id), do: AuditStore.records(audit_id)

  def delete_records(audit_id) when is_binary(audit_id), do: AuditStore.delete(audit_id)
  def verify_records(audit_id) when is_binary(audit_id), do: AuditStore.verify_chain(audit_id)

  def record_deletion(summary) when is_map(summary) do
    metadata =
      %{
        run_id: Map.get(summary, :run_id) || Map.get(summary, "run_id"),
        status: "deleted",
        reason: "run_artifacts_deleted",
        record_count:
          Map.get(summary, :audit_records_deleted) || Map.get(summary, "audit_records_deleted"),
        spill_count:
          Map.get(summary, :spilled_tool_results_deleted) ||
            Map.get(summary, "spilled_tool_results_deleted")
      }
      |> sanitize_metadata()

    AuditStore.put(
      "synaptic_deletions",
      metadata.run_id,
      :guardrail,
      :artifacts_deleted,
      metadata,
      7 * 24 * 60 * 60 * 1000
    )

    :ok
  end

  def reason_code({:validation_failed, _details}), do: "validation_failed"
  def reason_code({:factuality_failed, _issues}), do: "factuality_failed"
  def reason_code({:hook_denied, _surface, _reason}), do: "hook_denied"
  def reason_code({:hook_failure, _surface, _reason}), do: "hook_failure"
  def reason_code({:mcp_governance_denied, _server, _reason}), do: "mcp_governance_denied"
  def reason_code({name, _detail}) when is_atom(name), do: Atom.to_string(name)
  def reason_code(name) when is_atom(name), do: Atom.to_string(name)
  def reason_code(name) when is_binary(name), do: name
  def reason_code(_other), do: "error"

  def issue_codes({:validation_failed, %{issues: issues}}), do: extract_issue_codes(issues)

  def issue_codes({:factuality_failed, issues}) when is_list(issues),
    do: extract_issue_codes(issues)

  def issue_codes(_reason), do: []

  defp maybe_attach_metadata({:ok, content}, %{config: %{return_metadata: true}} = state) do
    if state.record_count > 0 do
      {:ok, content, %{audit: %{audit_id: state.audit_id, record_count: state.record_count}}}
    else
      {:ok, content}
    end
  end

  defp maybe_attach_metadata({:ok, content, meta}, %{config: %{return_metadata: true}} = state) do
    if state.record_count > 0 do
      {:ok, content,
       Map.put(meta, :audit, %{audit_id: state.audit_id, record_count: state.record_count})}
    else
      {:ok, content, meta}
    end
  end

  defp maybe_attach_metadata(result, _state), do: result

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:audit)
      |> normalize_config()

    merge_config(global, per_call)
  end

  defp normalize_config(nil), do: %{}
  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}

  defp normalize_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "audit config must be a keyword list, map, boolean, or nil, got: #{inspect(config)}"
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
      retention_ms: normalize_positive_integer(fetch_value(config, :retention_ms)),
      categories: normalize_categories(fetch_value(config, :categories))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "audit config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(
      :categories,
      @default_config.categories
      |> Map.merge(Map.get(global, :categories, %{}))
      |> Map.merge(Map.get(per_call, :categories, %{}))
    )
  end

  defp normalize_categories(nil), do: nil

  defp normalize_categories(categories) when is_list(categories) do
    unless Keyword.keyword?(categories) do
      raise ArgumentError, "audit categories must be a keyword list or map"
    end

    categories
    |> Enum.into(%{})
    |> normalize_categories()
  end

  defp normalize_categories(%{} = categories) do
    categories
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case normalize_category(key) do
        nil -> acc
        normalized -> Map.put(acc, normalized, normalize_boolean(value))
      end
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_categories(_other), do: nil

  defp category_enabled?(config, category) do
    config
    |> Map.get(:categories, %{})
    |> Map.get(category, true)
  end

  defp base_metadata(state) do
    %{
      run_id: state.run_id,
      step_name: state.step_name,
      tenant: state.tenant,
      workflow: state.workflow,
      record_count: state.record_count + 1
    }
  end

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      normalized_key = normalize_key(key)

      if normalized_key in @allowed_metadata_keys do
        case sanitize_value(value) do
          nil -> acc
          sanitized -> Map.put(acc, normalized_key, sanitized)
        end
      else
        acc
      end
    end)
  end

  defp sanitize_value(nil), do: nil
  defp sanitize_value(value) when is_boolean(value), do: value
  defp sanitize_value(value) when is_integer(value), do: value
  defp sanitize_value(value) when is_float(value), do: value
  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize_value(value) when is_binary(value) do
    value
    |> Redaction.scrub()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 160)
  end

  defp sanitize_value(values) when is_list(values) do
    values
    |> Enum.map(&sanitize_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(20)
    |> case do
      [] -> nil
      sanitized -> sanitized
    end
  end

  defp sanitize_value(_other), do: nil

  defp maybe_emit(metadata, %{emit_telemetry: true}) do
    :telemetry.execute([:synaptic, :audit, :record], %{count: 1}, metadata)
  end

  defp maybe_emit(_metadata, _config), do: :ok

  defp extract_issue_codes(issues) do
    issues
    |> Enum.map(fn issue ->
      Map.get(issue, :code) || Map.get(issue, "code")
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&sanitize_value/1)
  end

  defp normalize_category(value) when value in [:chat, :tool, :workflow, :guardrail, :judgment],
    do: value

  defp normalize_category(value) when is_binary(value) do
    case String.downcase(value) do
      "chat" -> :chat
      "tool" -> :tool
      "workflow" -> :workflow
      "guardrail" -> :guardrail
      "judgment" -> :judgment
      _ -> nil
    end
  end

  defp normalize_category(_value), do: nil

  defp normalize_boolean(value) when value in [true, false], do: value
  defp normalize_boolean("true"), do: true
  defp normalize_boolean("false"), do: false
  defp normalize_boolean(_value), do: nil

  defp normalize_booleanish(nil), do: nil
  defp normalize_booleanish(value), do: normalize_boolean(value)

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    normalized =
      key
      |> String.downcase()
      |> String.replace("-", "_")

    Enum.find(@allowed_metadata_keys, fn allowed ->
      Atom.to_string(allowed) == normalized
    end) || :unknown
  end

  defp normalize_key(_key), do: :unknown

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp generate_audit_id do
    "audit_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp get_from_context(key) do
    case Process.get({:synaptic_context, key}) do
      nil -> nil
      value -> value
    end
  end
end
