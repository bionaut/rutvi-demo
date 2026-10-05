defmodule Synaptic.Validation do
  @moduledoc false

  alias ExJsonSchema.Schema
  alias ExJsonSchema.Validator
  alias ExJsonSchema.Validator.Error

  # Resume schemas were enforced before the generalized validation boundary
  # existed. Keep that fail-closed contract by default while leaving workflow
  # input/output validation opt-in for backwards compatibility.
  @default_step_validation [input: :off, output: :off, resume: :subset]
  @valid_contract_modes [:subset, :strict, :off]
  @field_descriptor_keys [
    :type,
    :required,
    :enum,
    :min,
    :max,
    :minimum,
    :maximum,
    :min_length,
    :max_length,
    :minLength,
    :maxLength,
    :regex,
    :pattern,
    :fields
  ]

  @type issue :: %{
          path: String.t(),
          code: :missing_required | :type_mismatch | :unexpected_field | :invalid_json,
          message: String.t()
        }

  @type failure :: {:validation_failed, %{surface: atom(), step: atom() | nil, issues: [issue()]}}

  @type compiled_json_schema :: %{
          adapter_schema: map(),
          validation_schema: Schema.Root.t()
        }

  def default_step_validation do
    Application.get_env(:synaptic, __MODULE__, [])
    |> Keyword.get(:step_defaults, @default_step_validation)
    |> normalize_configured_step_defaults()
  end

  def runtime_step_defaults(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :validation_defaults) ||
           get_runtime_value(:__validation_step_defaults__) do
      nil -> default_step_validation()
      value -> normalize_configured_step_defaults(value)
    end
  end

  def default_tool_validation do
    Application.get_env(:synaptic, __MODULE__, [])
    |> Keyword.get(:tools, false)
  end

  def tool_validation_enabled?(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get(:validation)
    |> normalize_tool_validation_value()
  end

  def normalize_step_validation(nil), do: @default_step_validation

  def normalize_step_validation(%{} = validation) do
    validation
    |> Map.to_list()
    |> normalize_step_validation()
  end

  def normalize_step_validation(validation) when is_list(validation) do
    unless Keyword.keyword?(validation) do
      raise ArgumentError,
            "step validation must be a keyword list or map, got: #{inspect(validation)}"
    end

    invalid_keys =
      validation
      |> Keyword.keys()
      |> Enum.reject(&(&1 in [:input, :output, :resume]))

    if invalid_keys != [] do
      raise ArgumentError,
            "step validation supports only :input, :output, and :resume keys, got: #{inspect(invalid_keys)}"
    end

    normalized = Keyword.merge(default_step_validation(), validation)

    Enum.each(normalized, fn {surface, mode} ->
      unless mode in @valid_contract_modes do
        raise ArgumentError,
              "step validation for #{inspect(surface)} must be one of #{inspect(@valid_contract_modes)}, got: #{inspect(mode)}"
      end
    end)

    normalized
  end

  def validation_mode(validation, surface) when is_list(validation) do
    Keyword.get(validation, surface, Keyword.fetch!(default_step_validation(), surface))
  end

  def effective_step_validation(%{validation_declared: declared}) do
    effective_step_validation(declared, [])
  end

  def effective_step_validation(%{validation_declared: declared}, opts) when is_list(opts) do
    effective_step_validation(declared, opts)
  end

  def effective_step_validation(nil, opts) when is_list(opts) do
    runtime_step_defaults(opts)
  end

  def effective_step_validation(validation, opts) when is_list(validation) and is_list(opts) do
    runtime_step_defaults(opts)
    |> Keyword.merge(validation)
    |> normalize_step_validation()
  end

  def effective_step_validation(%{} = validation, opts) when is_list(opts) do
    validation
    |> Map.to_list()
    |> effective_step_validation(opts)
  end

  def validate_workflow_input(step_name, contract, validation, input) do
    validate_contract_surface(
      :workflow_input,
      step_name,
      input,
      contract,
      validation_mode(validation, :input)
    )
  end

  def validate_step_input(step_name, contract, validation, input) do
    validate_contract_surface(
      :step_input,
      step_name,
      input,
      contract,
      validation_mode(validation, :input)
    )
  end

  def validate_step_output(step_name, contract, validation, output) do
    validate_contract_surface(
      :step_output,
      step_name,
      output,
      contract,
      validation_mode(validation, :output)
    )
  end

  def validate_resume_payload(step_name, payload, contract, validation) do
    validate_contract_surface(
      :resume_payload,
      step_name,
      payload,
      contract,
      validation_mode(validation, :resume)
    )
  end

  def validation_failure(surface, step_name, issues) when is_list(issues) do
    {:validation_failed,
     %{
       surface: surface,
       step: step_name,
       issues: Enum.sort_by(issues, & &1.path)
     }}
  end

  def compile_json_schema(schema, opts \\ [])

  def compile_json_schema(schema, opts) when is_map(schema) do
    normalized_schema =
      schema
      |> normalize_json_value()
      |> apply_default_additional_properties()

    adapter_schema = sanitize_schema_for_openai(normalized_schema)

    if Keyword.get(opts, :validate_schema, true) do
      try do
        validation_schema = Schema.resolve(normalized_schema)

        {:ok,
         %{
           adapter_schema: adapter_schema,
           validation_schema: validation_schema
         }}
      rescue
        error in [
          Schema.InvalidSchemaError,
          Schema.InvalidReferenceError,
          Schema.UnsupportedSchemaVersionError
        ] ->
          {:error, Exception.message(error)}
      end
    else
      {:ok,
       %{
         adapter_schema: adapter_schema,
         validation_schema: nil
       }}
    end
  end

  def compile_json_schema(other, _opts),
    do: {:error, "expected schema map, got: #{inspect(other)}"}

  def validate_json_arguments(%{validation_schema: nil}, _args), do: :ok

  def validate_json_arguments(%{validation_schema: validation_schema}, args) when is_map(args) do
    validation_schema
    |> Validator.validate(normalize_contract_data(args), error_formatter: false)
    |> case do
      :ok -> :ok
      {:error, errors} -> {:error, Enum.flat_map(errors, &schema_error_to_issues/1)}
    end
  end

  def validate_json_arguments(_compiled_schema, _args) do
    {:error, [issue("#", :type_mismatch, "Expected arguments to be a JSON object.")]}
  end

  def invalid_json_issue(message \\ "Tool arguments must be a valid JSON object.") do
    [issue("#", :invalid_json, message)]
  end

  defp normalize_tool_validation_value(nil), do: default_tool_validation()
  defp normalize_tool_validation_value(false), do: false
  defp normalize_tool_validation_value(true), do: true

  defp normalize_tool_validation_value(%{} = validation) do
    validation
    |> Map.to_list()
    |> normalize_tool_validation_value()
  end

  defp normalize_tool_validation_value(validation) when is_list(validation) do
    Keyword.get(validation, :tools, default_tool_validation())
  end

  defp get_runtime_value(key) do
    case Process.get({:synaptic_context, key}) do
      nil -> nil
      value -> value
    end
  end

  defp normalize_configured_step_defaults(%{} = validation) do
    validation
    |> Map.to_list()
    |> normalize_configured_step_defaults()
  end

  defp normalize_configured_step_defaults(validation) when is_list(validation) do
    unless Keyword.keyword?(validation) do
      raise ArgumentError,
            "Synaptic.Validation step_defaults must be a keyword list or map, got: #{inspect(validation)}"
    end

    invalid_keys =
      validation
      |> Keyword.keys()
      |> Enum.reject(&(&1 in [:input, :output, :resume]))

    if invalid_keys != [] do
      raise ArgumentError,
            "Synaptic.Validation step_defaults supports only :input, :output, and :resume keys, got: #{inspect(invalid_keys)}"
    end

    normalized = Keyword.merge(@default_step_validation, validation)

    Enum.each(normalized, fn {surface, mode} ->
      unless mode in @valid_contract_modes do
        raise ArgumentError,
              "Synaptic.Validation step_defaults for #{inspect(surface)} must be one of #{inspect(@valid_contract_modes)}, got: #{inspect(mode)}"
      end
    end)

    normalized
  end

  defp validate_contract_surface(_surface, _step_name, _data, contract, :off)
       when map_size(contract) == 0,
       do: :ok

  defp validate_contract_surface(_surface, _step_name, _data, contract, _mode)
       when map_size(contract) == 0,
       do: :ok

  defp validate_contract_surface(_surface, _step_name, _data, _contract, :off), do: :ok

  defp validate_contract_surface(surface, step_name, data, contract, mode) do
    case validate_contract(data, contract, mode) do
      :ok -> :ok
      {:error, issues} -> {:error, validation_failure(surface, step_name, issues)}
    end
  end

  defp validate_contract(data, contract, mode) when is_map(data) and is_map(contract) do
    issues =
      data
      |> normalize_contract_data()
      |> contract_issues(normalize_contract(contract), "#", mode)

    if issues == [], do: :ok, else: {:error, issues}
  end

  defp validate_contract(_data, _contract, _mode) do
    {:error, [issue("#", :type_mismatch, "Expected value to be an object.")]}
  end

  defp contract_issues(data, contract, path, mode) do
    declared_keys = Map.keys(contract)

    declared_issues =
      Enum.flat_map(contract, fn {key, expected} ->
        key_path = join_path(path, key)
        required? = contract_field_required?(expected)

        case Map.fetch(data, key) do
          :error when required? ->
            [
              issue(
                key_path,
                :missing_required,
                "Required field #{inspect(key)} was not present."
              )
            ]

          :error ->
            []

          {:ok, value} ->
            validate_contract_value(value, expected, key_path, mode)
        end
      end)

    extra_issues =
      if mode == :strict do
        data
        |> Map.keys()
        |> Enum.reject(&(&1 in declared_keys))
        |> Enum.map(fn key ->
          issue(join_path(path, key), :unexpected_field, "Unexpected field #{inspect(key)}.")
        end)
      else
        []
      end

    declared_issues ++ extra_issues
  end

  defp validate_contract_value(value, %{__field__: true} = expected, path, mode) do
    type_issues =
      case expected.type do
        nil ->
          []

        type ->
          if matches_contract_type?(value, type) do
            []
          else
            [
              issue(
                path,
                :type_mismatch,
                "Type mismatch. Expected #{display_expected(type)} but got #{display_type(value)}."
              )
            ]
          end
      end

    nested_issues =
      case expected.fields do
        nil ->
          []

        fields when is_map(fields) ->
          if is_map(value) do
            contract_issues(normalize_contract_data(value), fields, path, mode)
          else
            [
              issue(
                path,
                :type_mismatch,
                "Type mismatch. Expected Map but got #{display_type(value)}."
              )
            ]
          end
      end

    constraint_issues =
      if type_issues == [] and nested_issues == [] do
        contract_constraint_issues(value, expected, path)
      else
        []
      end

    type_issues ++ nested_issues ++ constraint_issues
  end

  defp validate_contract_value(value, expected, path, mode) when is_map(expected) do
    if is_map(value) do
      contract_issues(normalize_contract_data(value), normalize_contract(expected), path, mode)
    else
      [issue(path, :type_mismatch, "Type mismatch. Expected Map but got #{display_type(value)}.")]
    end
  end

  defp validate_contract_value(value, expected, path, _mode) do
    if matches_contract_type?(value, expected) do
      []
    else
      [
        issue(
          path,
          :type_mismatch,
          "Type mismatch. Expected #{display_expected(expected)} but got #{display_type(value)}."
        )
      ]
    end
  end

  defp normalize_contract(contract) do
    Map.new(contract, fn {key, value} ->
      normalized_key = normalize_contract_key(key)
      normalized_value = normalize_contract_value(value)
      {normalized_key, normalized_value}
    end)
  end

  defp normalize_contract_value(value) when is_list(value) do
    if Keyword.keyword?(value) and field_descriptor_keyword?(value) do
      normalize_field_descriptor(value)
    else
      value
    end
  end

  defp normalize_contract_value(value) when is_map(value), do: normalize_contract(value)
  defp normalize_contract_value(value), do: value

  defp normalize_contract_data(data) when is_map(data) do
    Map.new(data, fn {key, value} ->
      normalized_key = normalize_contract_key(key)

      normalized_value =
        cond do
          is_map(value) -> normalize_contract_data(value)
          is_list(value) -> Enum.map(value, &normalize_contract_list_value/1)
          is_binary(value) -> canonicalize_validation_string(value)
          true -> value
        end

      {normalized_key, normalized_value}
    end)
  end

  defp normalize_contract_list_value(value) when is_map(value), do: normalize_contract_data(value)

  defp normalize_contract_list_value(value) when is_list(value),
    do: Enum.map(value, &normalize_contract_list_value/1)

  defp normalize_contract_list_value(value) when is_binary(value),
    do: canonicalize_validation_string(value)

  defp normalize_contract_list_value(value), do: value

  defp normalize_contract_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_contract_key(key) when is_binary(key), do: key
  defp normalize_contract_key(key), do: to_string(key)

  defp matches_contract_type?(value, :string), do: is_binary(value)
  defp matches_contract_type?(value, :boolean), do: is_boolean(value)
  defp matches_contract_type?(value, :integer), do: is_integer(value)
  defp matches_contract_type?(value, :float), do: is_float(value)
  defp matches_contract_type?(value, :number), do: is_number(value)
  defp matches_contract_type?(value, :map), do: is_map(value)
  defp matches_contract_type?(value, :binary), do: is_binary(value)
  defp matches_contract_type?(value, :list), do: is_list(value)
  defp matches_contract_type?(value, :atom), do: is_atom(value)
  defp matches_contract_type?(_value, :any), do: true
  defp matches_contract_type?(_value, _type), do: true

  defp contract_constraint_issues(value, expected, path) do
    canonical_value = canonicalize_constraint_value(value)

    []
    |> maybe_add_enum_issue(canonical_value, expected, path)
    |> maybe_add_length_issues(canonical_value, expected, path)
    |> maybe_add_bounds_issues(canonical_value, expected, path)
    |> maybe_add_regex_issue(canonical_value, expected, path)
  end

  defp maybe_add_enum_issue(issues, _value, %{enum: nil}, _path), do: issues

  defp maybe_add_enum_issue(issues, value, %{enum: allowed}, path) do
    canonical_allowed = Enum.map(allowed, &canonicalize_constraint_value/1)

    if value in canonical_allowed do
      issues
    else
      issues ++
        [
          issue(
            path,
            :type_mismatch,
            "Value must be one of #{inspect(Enum.map(allowed, &display_constraint_value/1))}."
          )
        ]
    end
  end

  defp maybe_add_length_issues(issues, _value, %{min_length: nil, max_length: nil}, _path),
    do: issues

  defp maybe_add_length_issues(issues, value, expected, path) do
    case length_of(value) do
      {:ok, length} ->
        issues
        |> maybe_add_min_length_issue(length, expected.min_length, path)
        |> maybe_add_max_length_issue(length, expected.max_length, path)

      :error ->
        issues ++
          [
            issue(
              path,
              :type_mismatch,
              "Length constraints require a String or List value."
            )
          ]
    end
  end

  defp maybe_add_min_length_issue(issues, _length, nil, _path), do: issues

  defp maybe_add_min_length_issue(issues, length, minimum, path) do
    if length >= minimum do
      issues
    else
      issues ++
        [issue(path, :type_mismatch, "Value must be at least #{minimum} characters long.")]
    end
  end

  defp maybe_add_max_length_issue(issues, _length, nil, _path), do: issues

  defp maybe_add_max_length_issue(issues, length, maximum, path) do
    if length <= maximum do
      issues
    else
      issues ++
        [issue(path, :type_mismatch, "Value must be at most #{maximum} characters long.")]
    end
  end

  defp maybe_add_bounds_issues(issues, _value, %{min: nil, max: nil}, _path), do: issues

  defp maybe_add_bounds_issues(issues, value, expected, path) do
    if is_number(value) do
      issues
      |> maybe_add_min_issue(value, expected.min, path)
      |> maybe_add_max_issue(value, expected.max, path)
    else
      issues ++
        [
          issue(
            path,
            :type_mismatch,
            "Numeric bounds require an Integer, Float, or Number value."
          )
        ]
    end
  end

  defp maybe_add_min_issue(issues, _value, nil, _path), do: issues

  defp maybe_add_min_issue(issues, value, minimum, path) do
    if value >= minimum do
      issues
    else
      issues ++ [issue(path, :type_mismatch, "Value must be at least #{inspect(minimum)}.")]
    end
  end

  defp maybe_add_max_issue(issues, _value, nil, _path), do: issues

  defp maybe_add_max_issue(issues, value, maximum, path) do
    if value <= maximum do
      issues
    else
      issues ++ [issue(path, :type_mismatch, "Value must be at most #{inspect(maximum)}.")]
    end
  end

  defp maybe_add_regex_issue(issues, _value, %{regex: nil}, _path), do: issues

  defp maybe_add_regex_issue(issues, value, %{regex: regex}, path) do
    cond do
      not is_binary(value) ->
        issues ++
          [issue(path, :type_mismatch, "Regex constraints require a String value.")]

      Regex.match?(regex, value) ->
        issues

      true ->
        issues ++ [issue(path, :type_mismatch, "Value did not match the required format.")]
    end
  end

  defp normalize_field_descriptor(descriptor) do
    descriptor_map =
      descriptor
      |> Enum.into(%{})

    fields = fetch_descriptor_value(descriptor_map, :fields)
    type = fetch_descriptor_value(descriptor_map, :type)

    %{
      __field__: true,
      type: normalize_descriptor_type(type, fields),
      required: normalize_descriptor_required(fetch_descriptor_value(descriptor_map, :required)),
      enum: normalize_descriptor_enum(fetch_descriptor_value(descriptor_map, :enum)),
      min: normalize_descriptor_number(fetch_descriptor_value(descriptor_map, :min)),
      max: normalize_descriptor_number(fetch_descriptor_value(descriptor_map, :max)),
      min_length:
        normalize_descriptor_integer(
          fetch_descriptor_value(descriptor_map, :min_length) ||
            fetch_descriptor_value(descriptor_map, :minimum_length)
        ),
      max_length:
        normalize_descriptor_integer(
          fetch_descriptor_value(descriptor_map, :max_length) ||
            fetch_descriptor_value(descriptor_map, :maximum_length)
        ),
      regex:
        normalize_descriptor_regex(
          fetch_descriptor_value(descriptor_map, :regex) ||
            fetch_descriptor_value(descriptor_map, :pattern)
        ),
      fields: if(is_map(fields), do: normalize_contract(fields), else: nil)
    }
  end

  defp field_descriptor_keyword?(descriptor) do
    descriptor
    |> Keyword.keys()
    |> Enum.any?(&(&1 in @field_descriptor_keys))
  end

  defp contract_field_required?(%{__field__: true, required: required}), do: required
  defp contract_field_required?(_expected), do: true

  defp fetch_descriptor_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        string_key = Atom.to_string(key)

        Map.get(map, string_key) ||
          Map.get(map, camelize_descriptor_key(key))
    end
  end

  defp normalize_descriptor_type(nil, fields) when is_map(fields), do: :map
  defp normalize_descriptor_type(nil, _fields), do: nil
  defp normalize_descriptor_type(type, _fields), do: type

  defp normalize_descriptor_required(nil), do: true
  defp normalize_descriptor_required(required) when required in [true, false], do: required
  defp normalize_descriptor_required(_required), do: true

  defp normalize_descriptor_enum(nil), do: nil
  defp normalize_descriptor_enum(values) when is_list(values), do: values
  defp normalize_descriptor_enum(value), do: [value]

  defp normalize_descriptor_integer(nil), do: nil
  defp normalize_descriptor_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_descriptor_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_descriptor_integer(_value), do: nil

  defp normalize_descriptor_number(nil), do: nil
  defp normalize_descriptor_number(value) when is_number(value), do: value

  defp normalize_descriptor_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_descriptor_number(_value), do: nil

  defp normalize_descriptor_regex(nil), do: nil
  defp normalize_descriptor_regex(%Regex{} = regex), do: regex

  defp normalize_descriptor_regex(pattern) when is_binary(pattern) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} ->
        regex

      {:error, reason} ->
        raise ArgumentError, "invalid validation regex #{inspect(pattern)}: #{inspect(reason)}"
    end
  end

  defp normalize_descriptor_regex(other) do
    raise ArgumentError,
          "validation regex must be a Regex or string pattern, got: #{inspect(other)}"
  end

  defp length_of(value) when is_binary(value), do: {:ok, String.length(value)}
  defp length_of(value) when is_list(value), do: {:ok, length(value)}
  defp length_of(_value), do: :error

  defp canonicalize_constraint_value(value) when is_binary(value),
    do: canonicalize_validation_string(value)

  defp canonicalize_constraint_value(value) when is_list(value),
    do: Enum.map(value, &canonicalize_constraint_value/1)

  defp canonicalize_constraint_value(value), do: value

  defp canonicalize_validation_string(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.normalize(:nfc)
    |> String.trim()
  end

  defp camelize_descriptor_key(key) do
    key
    |> Atom.to_string()
    |> String.split("_")
    |> case do
      [head | tail] -> head <> Enum.map_join(tail, "", &String.capitalize/1)
      [] -> ""
    end
  end

  defp display_constraint_value(value) when is_binary(value),
    do: canonicalize_validation_string(value)

  defp display_constraint_value(value), do: value

  defp display_expected(expected) when is_atom(expected) do
    expected
    |> Atom.to_string()
    |> String.capitalize()
  end

  defp display_expected(expected), do: inspect(expected)

  defp display_type(value) when is_nil(value), do: "Null"
  defp display_type(value) when is_binary(value), do: "String"
  defp display_type(value) when is_boolean(value), do: "Boolean"
  defp display_type(value) when is_integer(value), do: "Integer"
  defp display_type(value) when is_float(value), do: "Float"
  defp display_type(value) when is_list(value), do: "List"
  defp display_type(value) when is_map(value), do: "Map"
  defp display_type(value) when is_atom(value), do: "Atom"
  defp display_type(_value), do: "Unknown"

  defp join_path("#", key), do: "#/" <> escape_path_segment(key)
  defp join_path(path, key), do: path <> "/" <> escape_path_segment(key)

  defp escape_path_segment(key) do
    key
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp issue(path, code, message), do: %{path: path, code: code, message: message}

  defp schema_error_to_issues(%Error{error: %Error.Required{missing: missing}, path: path}) do
    Enum.map(missing, fn key ->
      issue(
        join_path(path || "#", key),
        :missing_required,
        "Required field #{inspect(key)} was not present."
      )
    end)
  end

  defp schema_error_to_issues(%Error{error: %Error.AdditionalProperties{}, path: path}) do
    [issue(path || "#", :unexpected_field, "Unexpected field #{inspect(path_segment(path))}.")]
  end

  defp schema_error_to_issues(%Error{error: %Error.Type{} = error, path: path}) do
    [issue(path || "#", :type_mismatch, to_string(error))]
  end

  defp schema_error_to_issues(%Error{error: error, path: path}) do
    [issue(path || "#", :type_mismatch, to_string(error))]
  end

  defp path_segment(nil), do: ""
  defp path_segment("#"), do: "#"

  defp path_segment(path) do
    path
    |> String.split("/", trim: true)
    |> List.last()
    |> case do
      nil ->
        ""

      segment ->
        segment
        |> String.replace("~1", "/")
        |> String.replace("~0", "~")
    end
  end

  defp normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {normalize_contract_key(key), normalize_json_value(nested_value)}
    end)
  end

  defp normalize_json_value(value) when is_list(value),
    do: Enum.map(value, &normalize_json_value/1)

  defp normalize_json_value(true), do: true
  defp normalize_json_value(false), do: false
  defp normalize_json_value(nil), do: nil
  defp normalize_json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json_value(value), do: value

  defp apply_default_additional_properties(schema) when is_map(schema) do
    schema =
      Map.new(schema, fn {key, value} ->
        {key, apply_default_additional_properties(value)}
      end)

    properties = Map.get(schema, "properties")

    if is_map(properties) and not Map.has_key?(schema, "additionalProperties") do
      Map.put(schema, "additionalProperties", false)
    else
      schema
    end
  end

  defp apply_default_additional_properties(value) when is_list(value) do
    Enum.map(value, &apply_default_additional_properties/1)
  end

  defp apply_default_additional_properties(value), do: value

  # OpenAI function calling requires top-level type: "object" and forbids
  # oneOf/anyOf/allOf/enum/not at the root. We recursively sanitize schemas
  # so rich JSON Schema still works when exposed as tools.
  defp sanitize_schema_for_openai(schema) when is_map(schema) do
    schema
    |> collapse_root_combinators()
    |> strip_top_level_combinators()
    |> ensure_object_type()
    |> sanitize_properties()
  end

  defp sanitize_schema_for_openai(other), do: other

  defp collapse_root_combinators(schema) do
    combo = Map.get(schema, "anyOf") || Map.get(schema, "oneOf") || Map.get(schema, "allOf")
    type = Map.get(schema, "type")

    cond do
      !is_list(combo) or combo == [] ->
        schema

      type == "object" ->
        existing_props = Map.get(schema, "properties") || %{}
        existing_required = Map.get(schema, "required") || []

        {merged_props, merged_required} =
          Enum.reduce(combo, {existing_props, existing_required}, fn variant, {props, req} ->
            if is_map(variant) do
              vp = Map.get(variant, "properties") || %{}
              vr = Map.get(variant, "required") || []
              {Map.merge(props, vp), Enum.uniq(req ++ vr)}
            else
              {props, req}
            end
          end)

        schema
        |> Map.put("properties", merged_props)
        |> then(fn updated ->
          if merged_required != [],
            do: Map.put(updated, "required", merged_required),
            else: updated
        end)

      true ->
        chosen =
          Enum.find(combo, fn variant ->
            is_map(variant) and Map.get(variant, "type") == "object"
          end) || List.first(combo)

        chosen = if is_map(chosen), do: chosen, else: %{"type" => "object", "properties" => %{}}

        chosen
        |> maybe_put_if_missing("description", Map.get(schema, "description"))
        |> maybe_put_if_missing("title", Map.get(schema, "title"))
    end
  end

  defp ensure_object_type(schema) do
    if Map.get(schema, "type") == "object" do
      schema
    else
      %{
        "type" => "object",
        "properties" => %{"value" => strip_top_level_combinators(schema)},
        "required" => ["value"],
        "additionalProperties" => false
      }
    end
  end

  defp sanitize_properties(schema) do
    props = Map.get(schema, "properties") || %{}

    sanitized_props =
      if is_map(props) do
        Map.new(props, fn {key, prop_schema} ->
          {key, sanitize_property(prop_schema)}
        end)
      else
        %{}
      end

    schema
    |> Map.put("properties", sanitized_props)
    |> Map.delete("enum")
    |> Map.delete("not")
  end

  defp sanitize_property(schema) when is_map(schema) do
    cond do
      combo = Map.get(schema, "anyOf") || Map.get(schema, "oneOf") ->
        pick_best_variant(combo, schema)

      Map.get(schema, "type") == "object" ->
        sanitize_properties(schema)

      Map.get(schema, "type") == "array" ->
        items = Map.get(schema, "items")

        if is_map(items) do
          Map.put(schema, "items", sanitize_property(items))
        else
          schema
        end

      true ->
        schema
    end
  end

  defp sanitize_property(other), do: other

  defp pick_best_variant(variants, original_schema) when is_list(variants) do
    best =
      Enum.find(variants, fn variant ->
        type = Map.get(variant, "type")
        type != nil and type != "null"
      end)

    base = sanitize_property(best || %{"type" => "string"})

    if description = Map.get(original_schema, "description") do
      Map.put(base, "description", description)
    else
      base
    end
  end

  defp strip_top_level_combinators(schema) do
    Map.drop(schema, ["oneOf", "anyOf", "allOf", "enum", "not"])
  end

  defp maybe_put_if_missing(map, key, value) do
    if Map.has_key?(map, key) or is_nil(value) do
      map
    else
      Map.put(map, key, value)
    end
  end
end
