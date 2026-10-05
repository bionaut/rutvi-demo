defmodule Synaptic.Privacy do
  @moduledoc false

  @valid_actions [:allow, :mask, :tokenize, :drop]
  @pii_types [:email, :phone, :ssn, :payment_card, :auth_token, :dob, :address]

  @default_config %{
    enabled: false,
    return_metadata: false,
    detectors: @pii_types,
    prompt: %{
      enabled: true,
      default_action: :tokenize,
      field_actions: %{},
      type_actions: %{"auth_token" => :drop},
      derived_facts: false,
      include_tokens_in_facts: false
    },
    output: %{
      enabled: true,
      default_action: :mask,
      field_actions: %{},
      type_actions: %{"auth_token" => :drop},
      rehydrate: false
    }
  }

  @email_regex ~r/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
  @ssn_regex ~r/\b\d{3}-?\d{2}-?\d{4}\b/
  @phone_regex ~r/(?<!\w)(?:\+?\d[\d\-\.\(\) ]{8,}\d)(?!\w)/
  @dob_regex ~r/\b(?:\d{4}-\d{2}-\d{2}|\d{1,2}[\/-]\d{1,2}[\/-]\d{2,4})\b/
  @card_regex ~r/(?<!\w)(?:\d[ -]*?){13,19}(?!\w)/

  @type action :: :allow | :mask | :tokenize | :drop
  @type pii_type :: :email | :phone | :ssn | :payment_card | :auth_token | :dob | :address

  @type state :: %{
          config: map(),
          counters: %{optional(pii_type()) => non_neg_integer()},
          by_value: %{optional({pii_type(), String.t()}) => String.t()},
          by_token: %{optional(String.t()) => %{type: pii_type(), value: String.t()}},
          detections: [map()]
        }

  def new(opts) when is_list(opts) do
    %{
      config: resolve_config(opts),
      counters: %{},
      by_value: %{},
      by_token: %{},
      detections: []
    }
  end

  def enabled?(%{config: %{enabled: true}}), do: true
  def enabled?(_state), do: false

  # Structured model inputs share prompt privacy rules without becoming chat messages.
  def prepare_data(data, %{} = state) do
    if enabled?(state) and get_in(state, [:config, :prompt, :enabled]) do
      sanitize(data, state, :prompt, %{
        field_name: nil,
        field_type: nil,
        provenance: :user_provided,
        source_kind: :user_input
      })
    else
      {data, state}
    end
  end

  def prepare_messages(messages, %{} = state) when is_list(messages) do
    if enabled?(state) and get_in(state, [:config, :prompt, :enabled]) do
      Enum.map_reduce(messages, state, fn message, current_state ->
        content = Map.get(message, :content, Map.get(message, "content"))
        source_kind = prompt_source_kind(message)
        provenance = provenance_for(:prompt, source_kind)

        {sanitized_content, updated_state} =
          sanitize(content, current_state, :prompt, %{
            field_name: nil,
            field_type: nil,
            provenance: provenance,
            source_kind: source_kind
          })

        updated_message =
          cond do
            Map.has_key?(message, :content) -> Map.put(message, :content, sanitized_content)
            Map.has_key?(message, "content") -> Map.put(message, "content", sanitized_content)
            true -> Map.put(message, :content, sanitized_content)
          end

        {updated_message, updated_state}
      end)
    else
      {messages, state}
    end
  end

  def sanitize_result({:ok, content}, %{} = state) do
    {sanitized_content, state} = sanitize_output(content, state)
    {{:ok, sanitized_content}, state}
  end

  def sanitize_result({:ok, content, meta}, %{} = state) when is_map(meta) do
    {sanitized_content, state} = sanitize_output(content, state)
    {{:ok, sanitized_content, meta}, state}
  end

  def sanitize_result({:error, _reason} = error, %{} = state), do: {error, state}
  def sanitize_result(other, %{} = state), do: {other, state}

  def sanitize_tool_result(result, %{} = state, source_kind \\ :tool_derived) do
    if enabled?(state) and get_in(state, [:config, :prompt, :enabled]) do
      sanitize(result, state, :prompt, %{
        field_name: nil,
        field_type: nil,
        provenance: provenance_for(:prompt, source_kind),
        source_kind: source_kind
      })
    else
      {result, state}
    end
  end

  def finalize_result({:ok, content}, %{} = state) do
    maybe_attach_metadata({:ok, maybe_rehydrate(content, state)}, state)
  end

  def finalize_result({:ok, content, meta}, %{} = state) when is_map(meta) do
    maybe_attach_metadata({:ok, maybe_rehydrate(content, state), meta}, state)
  end

  def finalize_result(other, _state), do: other

  def preview_stream_output(accumulated, %{} = state) when is_binary(accumulated) do
    if enabled?(state) and get_in(state, [:config, :output, :enabled]) do
      accumulated
      |> sanitize_preview(state, :output)
      |> maybe_rehydrate_preview(state)
    else
      maybe_rehydrate_preview(accumulated, state)
    end
  end

  def preview_stream_output(accumulated, _state), do: accumulated

  def rehydrate_tool_args(term, %{} = state) do
    if enabled?(state) do
      rehydrate(term, state)
    else
      term
    end
  end

  defp sanitize_output(content, %{} = state) do
    if enabled?(state) and get_in(state, [:config, :output, :enabled]) do
      sanitize(content, state, :output, %{
        field_name: nil,
        field_type: nil,
        provenance: :model_generated,
        source_kind: :model_generated
      })
    else
      {content, state}
    end
  end

  defp maybe_rehydrate(content, %{} = state) do
    if enabled?(state) and get_in(state, [:config, :output, :rehydrate]) do
      rehydrate(content, state)
    else
      content
    end
  end

  defp maybe_rehydrate_preview(content, %{} = state) do
    if enabled?(state) and get_in(state, [:config, :output, :rehydrate]) do
      rehydrate(content, state)
    else
      content
    end
  end

  defp sanitize(term, %{} = state, surface, context) do
    field_name = Map.get(context, :field_name)
    field_type = Map.get(context, :field_type)
    provenance = provenance_from_context(surface, Map.get(context, :provenance))
    source_kind = source_kind_from_context(surface, Map.get(context, :source_kind))

    cond do
      is_map(term) ->
        sanitize_map(term, state, surface, %{
          provenance: provenance,
          source_kind: source_kind
        })

      is_list(term) ->
        sanitize_list(term, state, surface, %{
          field_name: field_name,
          field_type: field_type,
          provenance: provenance,
          source_kind: source_kind
        })

      is_binary(term) ->
        sanitize_string(term, state, surface, field_name, field_type, %{
          provenance: provenance,
          source_kind: source_kind
        })

      true ->
        {term, state}
    end
  end

  defp sanitize_map(map, %{} = state, surface, source_context) do
    Enum.reduce(map, {%{}, state}, fn {key, value}, {acc, current_state} ->
      field_name = normalize_field_name(key)
      field_type = classify_field(field_name)
      action = action_for(current_state, surface, field_name, field_type)

      context =
        Map.merge(source_context, %{
          field_name: field_name,
          field_type: field_type
        })

      cond do
        action == :drop and primitive?(value) ->
          {acc,
           record_detection(
             current_state,
             surface,
             field_name,
             field_type,
             inspect(value),
             context
           )}

        derived_facts_enabled?(current_state, surface) and primitive?(value) and field_type != nil and
            action != :allow ->
          {facts, updated_state} =
            derived_fact_entries(
              key,
              value,
              current_state,
              surface,
              field_name,
              field_type,
              action,
              context
            )

          {Map.merge(acc, facts), updated_state}

        true ->
          {sanitized_value, updated_state} =
            sanitize(value, current_state, surface, %{
              field_name: field_name,
              field_type: field_type,
              provenance: context.provenance,
              source_kind: context.source_kind
            })

          {Map.put(acc, key, sanitized_value), updated_state}
      end
    end)
  end

  defp sanitize_list(list, %{} = state, surface, context) do
    Enum.map_reduce(list, state, fn value, current_state ->
      sanitize(value, current_state, surface, context)
    end)
  end

  defp sanitize_string(string, %{} = state, surface, field_name, field_type, context) do
    cond do
      string == "" ->
        {string, state}

      contains_known_token?(string, state) ->
        {string, state}

      field_type != nil ->
        action = action_for(state, surface, field_name, field_type)
        replace_entire_value(string, state, surface, field_name, field_type, action, context)

      json_candidate?(string) ->
        sanitize_json_string(string, state, surface, context)

      true ->
        sanitize_free_text(string, state, surface, context)
    end
  end

  defp sanitize_json_string(string, %{} = state, surface, context) do
    with {:ok, decoded} <- Jason.decode(string),
         true <- is_map(decoded) or is_list(decoded) do
      {sanitized_decoded, updated_state} =
        sanitize(decoded, state, surface, %{
          field_name: nil,
          field_type: nil,
          provenance: context.provenance,
          source_kind: context.source_kind
        })

      {Jason.encode!(sanitized_decoded), updated_state}
    else
      _ -> sanitize_free_text(string, state, surface, context)
    end
  end

  defp sanitize_free_text(string, %{} = state, surface, context) do
    detectors = Map.get(state.config, :detectors, @pii_types)

    Enum.reduce(detectors, {string, state}, fn type, {current_string, current_state} ->
      replace_detector_matches(current_string, current_state, surface, type, context)
    end)
  end

  defp replace_detector_matches(string, %{} = state, _surface, :address, _context),
    do: {string, state}

  defp replace_detector_matches(string, %{} = state, surface, type, context) do
    regex = detector_regex(type)

    matches =
      regex
      |> Regex.scan(string, return: :index)
      |> Enum.flat_map(fn
        [{start, length} | _] ->
          value = binary_part(string, start, length)
          if detector_match?(type, value), do: [{start, length, value}], else: []

        _ ->
          []
      end)
      |> Enum.uniq_by(fn {start, length, _value} -> {start, length} end)

    Enum.reduce(Enum.reverse(matches), {string, state}, fn {start, length, value},
                                                           {current_string, current_state} ->
      action = action_for(current_state, surface, nil, type)

      {replacement, updated_state} =
        replacement_for(value, current_state, surface, nil, type, action, context)

      {replace_range(current_string, start, length, replacement), updated_state}
    end)
  end

  defp replace_entire_value(
         value,
         %{} = state,
         surface,
         field_name,
         field_type,
         action,
         context
       ) do
    replacement_for(value, state, surface, field_name, field_type, action, context)
  end

  defp replacement_for(value, %{} = state, surface, field_name, field_type, action, context) do
    updated_state = record_detection(state, surface, field_name, field_type, value, context)

    case action do
      :allow ->
        {value, updated_state}

      :mask ->
        {mask_value(field_type, value), updated_state}

      :tokenize ->
        token_for(updated_state, field_type, value)

      :drop ->
        {drop_replacement(field_type), updated_state}
    end
  end

  defp token_for(%{} = state, type, value) do
    normalized_value = IO.iodata_to_binary(value)

    case Map.fetch(state.by_value, {type, normalized_value}) do
      {:ok, token} ->
        {token, state}

      :error ->
        count = Map.get(state.counters, type, 0) + 1
        token = "[PII_#{type |> Atom.to_string() |> String.upcase()}_#{count}]"

        updated_state =
          state
          |> put_in([:by_value, {type, normalized_value}], token)
          |> put_in([:by_token, token], %{type: type, value: normalized_value})
          |> put_in([:counters, type], count)

        {token, updated_state}
    end
  end

  defp action_for(%{} = state, surface, field_name, field_type) do
    surface_config = Map.fetch!(state.config, surface)

    field_action =
      case field_name do
        nil -> nil
        name -> Map.get(surface_config.field_actions, normalize_field_name(name))
      end

    type_action =
      case field_type do
        nil -> nil
        type -> Map.get(surface_config.type_actions, Atom.to_string(type))
      end

    field_action || type_action || surface_config.default_action
  end

  defp rehydrate(term, %{} = state) when is_map(term) do
    Map.new(term, fn {key, value} -> {key, rehydrate(value, state)} end)
  end

  defp rehydrate(term, %{} = state) when is_list(term) do
    Enum.map(term, &rehydrate(&1, state))
  end

  defp rehydrate(term, %{} = state) when is_binary(term) do
    state.by_token
    |> Enum.sort_by(fn {token, _meta} -> -byte_size(token) end)
    |> Enum.reduce(term, fn {token, %{value: value}}, acc ->
      String.replace(acc, token, value)
    end)
  end

  defp rehydrate(term, _state), do: term

  defp sanitize_preview(term, %{} = state, surface) do
    {preview, _preview_state} =
      sanitize(term, preview_state(state), surface, %{field_name: nil, field_type: nil})

    preview
  end

  defp preview_state(%{} = state) do
    %{state | detections: []}
  end

  defp maybe_attach_metadata({:ok, content}, %{config: %{return_metadata: true}} = state) do
    metadata = build_metadata(state)

    if metadata == %{} do
      {:ok, content}
    else
      {:ok, content, %{privacy: metadata}}
    end
  end

  defp maybe_attach_metadata({:ok, content, meta}, %{config: %{return_metadata: true}} = state) do
    metadata = build_metadata(state)

    if metadata == %{} do
      {:ok, content, meta}
    else
      {:ok, content, Map.put(meta, :privacy, metadata)}
    end
  end

  defp maybe_attach_metadata(result, _state), do: result

  defp build_metadata(%{detections: detections}) do
    %{}
    |> maybe_put(:detections, Enum.reverse(detections), detections != [])
    |> maybe_put(:detection_count, length(detections), detections != [])
    |> maybe_put(
      :sensitivity_levels,
      Enum.uniq(Enum.map(detections, & &1.sensitivity)),
      detections != []
    )
    |> maybe_put(:provenance, Enum.uniq(Enum.map(detections, & &1.provenance)), detections != [])
  end

  defp resolve_config(opts) do
    base =
      @default_config
      |> deep_merge(normalize_config(Application.get_env(:synaptic, __MODULE__, [])))

    case Keyword.get(opts, :privacy, :inherit) do
      :inherit ->
        base

      false ->
        Map.put(base, :enabled, false)

      true ->
        Map.put(base, :enabled, true)

      override ->
        override_config = normalize_config(override)

        override_config =
          if override_config != %{} and not Map.has_key?(override_config, :enabled) do
            Map.put(override_config, :enabled, true)
          else
            override_config
          end

        deep_merge(base, override_config)
    end
  end

  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}
  defp normalize_config(nil), do: %{}

  defp normalize_config(config) when is_list(config) do
    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    Enum.reduce(config, %{}, fn {key, value}, acc ->
      normalized_key = normalize_config_key(key)
      Map.put(acc, normalized_key, normalize_config_value(normalized_key, value))
    end)
  end

  defp normalize_config(_other), do: %{}

  defp normalize_config_value(:enabled, value), do: !!value
  defp normalize_config_value(:return_metadata, value), do: !!value
  defp normalize_config_value(:rehydrate, value), do: !!value

  defp normalize_config_value(:prompt, value), do: normalize_surface_config(value)
  defp normalize_config_value(:output, value), do: normalize_surface_config(value)

  defp normalize_config_value(:detectors, value) when is_list(value) do
    value
    |> Enum.map(&normalize_detector/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_config_value(:field_actions, value), do: normalize_action_map(value, :field)
  defp normalize_config_value(:type_actions, value), do: normalize_action_map(value, :type)
  defp normalize_config_value(:default_action, value), do: normalize_action(value) || :tokenize
  defp normalize_config_value(:derived_facts, value), do: !!value
  defp normalize_config_value(:include_tokens_in_facts, value), do: !!value
  defp normalize_config_value(_key, value), do: value

  defp normalize_surface_config(false), do: %{enabled: false}
  defp normalize_surface_config(true), do: %{enabled: true}
  defp normalize_surface_config(nil), do: %{}

  defp normalize_surface_config(config) when is_list(config) do
    config
    |> Enum.into(%{})
    |> normalize_surface_config()
  end

  defp normalize_surface_config(%{} = config) do
    Enum.reduce(config, %{}, fn {key, value}, acc ->
      normalized_key = normalize_config_key(key)
      Map.put(acc, normalized_key, normalize_config_value(normalized_key, value))
    end)
  end

  defp normalize_surface_config(_other), do: %{}

  defp normalize_action_map(value, mode) when is_list(value) do
    value
    |> Enum.into(%{})
    |> normalize_action_map(mode)
  end

  defp normalize_action_map(%{} = value, :field) do
    Map.new(value, fn {key, action} ->
      {normalize_field_name(key), normalize_action(action)}
    end)
  end

  defp normalize_action_map(%{} = value, :type) do
    Map.new(value, fn {key, action} ->
      {normalize_type_key(key), normalize_action(action)}
    end)
  end

  defp normalize_action_map(_value, _mode), do: %{}

  defp normalize_action(action) when is_atom(action) and action in @valid_actions, do: action

  defp normalize_action(action) when is_binary(action) do
    case String.downcase(action) do
      "allow" -> :allow
      "mask" -> :mask
      "tokenize" -> :tokenize
      "drop" -> :drop
      _ -> nil
    end
  end

  defp normalize_action(_action), do: nil

  defp normalize_detector(detector) when detector in @pii_types, do: detector

  defp normalize_detector(detector) when is_binary(detector) do
    detector
    |> String.downcase()
    |> case do
      "email" -> :email
      "phone" -> :phone
      "ssn" -> :ssn
      "payment_card" -> :payment_card
      "auth_token" -> :auth_token
      "dob" -> :dob
      "address" -> :address
      _ -> nil
    end
  end

  defp normalize_detector(_detector), do: nil

  defp normalize_config_key(key) when is_atom(key), do: key

  defp normalize_config_key(key) when is_binary(key) do
    case String.downcase(key) do
      "enabled" -> :enabled
      "return_metadata" -> :return_metadata
      "prompt" -> :prompt
      "output" -> :output
      "detectors" -> :detectors
      "field_actions" -> :field_actions
      "type_actions" -> :type_actions
      "default_action" -> :default_action
      "rehydrate" -> :rehydrate
      "derived_facts" -> :derived_facts
      "include_tokens_in_facts" -> :include_tokens_in_facts
      other -> other
    end
  end

  defp deep_merge(%{} = left, %{} = right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp detector_regex(:email), do: @email_regex
  defp detector_regex(:ssn), do: @ssn_regex
  defp detector_regex(:phone), do: @phone_regex
  defp detector_regex(:dob), do: @dob_regex
  defp detector_regex(:payment_card), do: @card_regex
  defp detector_regex(:auth_token), do: auth_token_regex()

  defp auth_token_regex do
    ~r/\b(?:sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z\-_]{20,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+)\b/
  end

  defp detector_match?(:phone, value) do
    digits = String.replace(value, ~r/\D/, "")
    String.length(digits) >= 10 and String.length(digits) <= 15
  end

  defp detector_match?(:payment_card, value) do
    digits = String.replace(value, ~r/\D/, "")
    String.length(digits) in 13..19 and luhn_valid?(digits)
  end

  defp detector_match?(:dob, value) do
    case parse_date_candidate(value) do
      {:ok, _date} -> true
      _ -> false
    end
  end

  defp detector_match?(_type, _value), do: true

  defp parse_date_candidate(value) do
    trimmed = String.trim(value)

    cond do
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, trimmed) ->
        Date.from_iso8601(trimmed)

      Regex.match?(~r/^\d{1,2}\/\d{1,2}\/\d{2,4}$/, trimmed) ->
        parse_slash_date(trimmed, "/")

      Regex.match?(~r/^\d{1,2}-\d{1,2}-\d{2,4}$/, trimmed) ->
        parse_slash_date(trimmed, "-")

      true ->
        :error
    end
  end

  defp parse_slash_date(value, separator) do
    case String.split(value, separator) do
      [first, second, third] ->
        with {month, ""} <- Integer.parse(first),
             {day, ""} <- Integer.parse(second),
             {year, ""} <- Integer.parse(third),
             normalized_year <- if(year < 100, do: 2000 + year, else: year),
             {:ok, date} <- Date.new(normalized_year, month, day) do
          {:ok, date}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp luhn_valid?(digits) do
    digits
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {digit, index}, acc ->
      value = String.to_integer(digit)

      adjusted =
        if rem(index, 2) == 1 do
          doubled = value * 2
          if doubled > 9, do: doubled - 9, else: doubled
        else
          value
        end

      acc + adjusted
    end)
    |> rem(10)
    |> Kernel.==(0)
  end

  defp classify_field(nil), do: nil

  defp classify_field(field_name) do
    normalized = normalize_field_name(field_name)

    cond do
      normalized in ["email", "emailaddress", "e-mail", "e-mailaddress"] ->
        :email

      normalized in ["phone", "phonenumber", "mobile", "mobilenumber", "telephone"] ->
        :phone

      normalized in ["ssn", "socialsecuritynumber", "socialsecurity"] ->
        :ssn

      normalized in [
        "cardnumber",
        "creditcard",
        "creditcardnumber",
        "paymentcard",
        "ccnumber",
        "pan"
      ] ->
        :payment_card

      normalized in [
        "token",
        "apikey",
        "secret",
        "accesstoken",
        "refreshtoken",
        "authtoken",
        "authorization",
        "password"
      ] ->
        :auth_token

      normalized in ["dob", "birthdate", "dateofbirth"] ->
        :dob

      normalized in [
        "address",
        "street",
        "streetaddress",
        "line1",
        "line2",
        "city",
        "state",
        "province",
        "postalcode",
        "zipcode",
        "zip"
      ] ->
        :address

      true ->
        nil
    end
  end

  defp normalize_field_name(field_name) do
    field_name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp normalize_type_key(type) when is_atom(type),
    do: type |> Atom.to_string() |> String.downcase()

  defp normalize_type_key(type) when is_binary(type), do: String.downcase(type)
  defp normalize_type_key(type), do: type |> to_string() |> String.downcase()

  defp record_detection(%{} = state, surface, field_name, field_type, value, context) do
    detected_type = field_type || classify_from_value(value)

    if detected_type do
      update_in(state.detections, fn detections ->
        [
          %{
            surface: surface,
            field: field_name,
            type: detected_type,
            sensitivity: sensitivity_level(detected_type),
            provenance: context.provenance,
            source_kind: context.source_kind,
            preview: preview_value(detected_type, value)
          }
          | detections
        ]
      end)
    else
      state
    end
  end

  defp classify_from_value(value) when is_binary(value) do
    Enum.find(@pii_types, fn type ->
      type != :address and detector_match?(type, value) and
        Regex.match?(detector_regex(type), value)
    end)
  end

  defp classify_from_value(_value), do: nil

  defp preview_value(type, value) when is_binary(value), do: mask_value(type, value)
  defp preview_value(_type, value), do: inspect(value)

  defp sensitivity_level(:auth_token), do: :secret
  defp sensitivity_level(type) when type in [:ssn, :payment_card, :dob], do: :restricted_pii
  defp sensitivity_level(type) when type in [:email, :phone, :address], do: :pii
  defp sensitivity_level(_type), do: :pii

  defp present_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_value?(value) when is_list(value), do: value != []
  defp present_value?(value) when is_map(value), do: map_size(value) > 0
  defp present_value?(nil), do: false
  defp present_value?(_value), do: true

  defp derived_facts_enabled?(%{} = state, :prompt) do
    get_in(state, [:config, :prompt, :derived_facts]) == true
  end

  defp derived_facts_enabled?(_state, _surface), do: false

  defp derived_fact_entries(
         key,
         value,
         %{} = state,
         surface,
         field_name,
         field_type,
         action,
         context
       ) do
    valid? = sensitive_value_valid?(field_type, value)
    base_key = key |> to_string() |> String.downcase()

    {token, updated_state} =
      if get_in(state, [:config, :prompt, :include_tokens_in_facts]) and action == :tokenize do
        token_for(
          record_detection(state, surface, field_name, field_type, value, context),
          field_type,
          value
        )
      else
        {nil, record_detection(state, surface, field_name, field_type, value, context)}
      end

    facts =
      %{
        "#{base_key}_present" => present_value?(value),
        "#{base_key}_valid" => valid?,
        "#{base_key}_type" => Atom.to_string(field_type),
        "#{base_key}_sensitivity" => Atom.to_string(sensitivity_level(field_type))
      }
      |> maybe_put("#{base_key}_token", token, not is_nil(token))

    {facts, updated_state}
  end

  defp sensitive_value_valid?(:address, value), do: present_value?(value)
  defp sensitive_value_valid?(type, value) when is_binary(value), do: detector_match?(type, value)
  defp sensitive_value_valid?(_type, _value), do: false

  defp provenance_for(:prompt, :user_input), do: :user_provided
  defp provenance_for(:prompt, :tool_derived), do: :tool_derived
  defp provenance_for(:prompt, :mcp_resource), do: :retrieved
  defp provenance_for(:prompt, :retrieval_result), do: :retrieved
  defp provenance_for(:output, _source_kind), do: :model_generated
  defp provenance_for(_surface, _source_kind), do: :unknown

  defp provenance_from_context(surface, nil),
    do: provenance_for(surface, source_kind_from_context(surface, nil))

  defp provenance_from_context(_surface, provenance), do: provenance

  defp source_kind_from_context(:prompt, nil), do: :user_input
  defp source_kind_from_context(:output, nil), do: :model_generated
  defp source_kind_from_context(_surface, source_kind), do: source_kind

  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value, false), do: map

  defp prompt_source_kind(message) do
    explicit =
      [
        Map.get(message, :source_kind),
        Map.get(message, "source_kind"),
        Map.get(message, :source),
        Map.get(message, "source"),
        get_in(message, [:metadata, :source_kind]),
        get_in(message, ["metadata", "source_kind"])
      ]
      |> Enum.find(&(!is_nil(&1)))

    case normalize_source_kind(explicit) do
      nil ->
        infer_prompt_source_kind_from_role(message)

      source_kind ->
        source_kind
    end
  end

  defp infer_prompt_source_kind_from_role(message) do
    role =
      message
      |> Map.get(:role, Map.get(message, "role", ""))
      |> to_string()

    cond do
      role == "user" ->
        :user_input

      role == "tool" and tool_resource_message?(message) ->
        :mcp_resource

      role == "tool" ->
        :tool_derived

      true ->
        :user_input
    end
  end

  defp tool_resource_message?(message) do
    name = Map.get(message, :name) || Map.get(message, "name") || ""
    String.ends_with?(name, "__read_resource") or String.ends_with?(name, "__list_resources")
  end

  defp normalize_source_kind(kind)
       when kind in [
              :user_input,
              :tool_derived,
              :mcp_resource,
              :retrieval_result,
              :model_generated
            ],
       do: kind

  defp normalize_source_kind(kind) when is_binary(kind) do
    case String.downcase(kind) do
      "user_input" -> :user_input
      "tool_derived" -> :tool_derived
      "tool_output" -> :tool_derived
      "mcp_resource" -> :mcp_resource
      "retrieval_result" -> :retrieval_result
      "retrieval" -> :retrieval_result
      "model_generated" -> :model_generated
      _ -> nil
    end
  end

  defp normalize_source_kind(_kind), do: nil

  defp mask_value(:email, value) do
    case String.split(value, "@", parts: 2) do
      [local, domain] ->
        local_prefix =
          case String.graphemes(local) do
            [first | _] -> first <> "***"
            _ -> "***"
          end

        local_prefix <> "@" <> domain

      _ ->
        "[REDACTED_EMAIL]"
    end
  end

  defp mask_value(:phone, value) do
    digits = String.replace(value, ~r/\D/, "")

    if String.length(digits) >= 4 do
      "***-***-" <> String.slice(digits, -4, 4)
    else
      "[REDACTED_PHONE]"
    end
  end

  defp mask_value(:ssn, value) do
    digits = String.replace(value, ~r/\D/, "")

    if String.length(digits) == 9 do
      "***-**-" <> String.slice(digits, -4, 4)
    else
      "[REDACTED_SSN]"
    end
  end

  defp mask_value(:payment_card, value) do
    digits = String.replace(value, ~r/\D/, "")

    if String.length(digits) >= 4 do
      "**** **** **** " <> String.slice(digits, -4, 4)
    else
      "[REDACTED_PAYMENT_CARD]"
    end
  end

  defp mask_value(:auth_token, value) do
    prefix = String.slice(value, 0, 4) || ""
    suffix = String.slice(value, -4, 4) || ""
    prefix <> "...#{suffix}"
  end

  defp mask_value(:dob, _value), do: "[REDACTED_DOB]"
  defp mask_value(:address, _value), do: "[REDACTED_ADDRESS]"
  defp mask_value(_type, _value), do: "[REDACTED]"

  defp drop_replacement(type) do
    "[#{type |> Atom.to_string() |> String.upcase()}_REMOVED]"
  end

  defp replace_range(string, start, length, replacement) do
    prefix = binary_part(string, 0, start)
    suffix = binary_part(string, start + length, byte_size(string) - start - length)
    prefix <> replacement <> suffix
  end

  defp primitive?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp json_candidate?(string) do
    trimmed = String.trim_leading(string)
    String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[")
  end

  defp contains_known_token?(string, %{} = state) do
    Enum.any?(Map.keys(state.by_token), &String.contains?(string, &1))
  end
end
