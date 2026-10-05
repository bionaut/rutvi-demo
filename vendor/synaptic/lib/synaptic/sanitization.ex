defmodule Synaptic.Sanitization do
  @moduledoc false

  @types [:html, :markdown, :url, :filename, :shell]

  @default_config %{
    enabled: false,
    prompt: %{
      enabled: true,
      roles: ["user"],
      types: [:html, :markdown]
    },
    tools: %{
      enabled: true,
      infer_fields: true,
      field_types: %{}
    },
    tool_results: %{
      enabled: false,
      infer_fields: true,
      field_types: %{},
      types: [:html, :markdown]
    },
    rules: %{
      html: %{action: :strip_tags},
      markdown: %{action: :plain_text},
      url: %{action: :drop_unsafe, allowed_schemes: ["http", "https", "mailto"]},
      filename: %{action: :basename},
      shell: %{action: :neutralize}
    }
  }

  @type state :: %{config: map()}

  def new(opts \\ []) when is_list(opts) do
    %{config: resolve_config(opts)}
  end

  def enabled?(%{config: %{enabled: true}}), do: true
  def enabled?(_state), do: false

  def prepare_data(data, %{} = state) do
    if enabled?(state) and get_in(state, [:config, :prompt, :enabled]) do
      sanitize_data(data, state)
    else
      {data, state}
    end
  end

  defp sanitize_data(data, state) when is_binary(data),
    do: sanitize_string(data, state.config.prompt.types, state, :prompt)

  defp sanitize_data(data, state) when is_map(data) do
    {entries, state} =
      Enum.map_reduce(data, state, fn {key, value}, acc ->
        {value, acc} = sanitize_data(value, acc)
        {{key, value}, acc}
      end)

    {Map.new(entries), state}
  end

  defp sanitize_data(data, state) when is_list(data),
    do: Enum.map_reduce(data, state, &sanitize_data/2)

  defp sanitize_data(data, state), do: {data, state}

  def prepare_messages(messages, %{} = state) when is_list(messages) do
    if enabled?(state) and get_in(state, [:config, :prompt, :enabled]) do
      roles = get_in(state, [:config, :prompt, :roles]) || []
      types = get_in(state, [:config, :prompt, :types]) || []

      Enum.map_reduce(messages, state, fn message, current_state ->
        role = message_role(message)

        if role in roles do
          case message_content(message) do
            content when is_binary(content) ->
              {sanitized_content, updated_state} =
                sanitize_string(content, types, current_state, :prompt)

              {put_message_content(message, sanitized_content), updated_state}

            _other ->
              {message, current_state}
          end
        else
          {message, current_state}
        end
      end)
    else
      {messages, state}
    end
  end

  def sanitize_tool_args(args, %{} = state) when is_map(args) do
    if enabled?(state) and get_in(state, [:config, :tools, :enabled]) do
      sanitize_tool_value(args, state, nil)
    else
      {args, state}
    end
  end

  def sanitize_tool_args(args, %{} = state), do: {args, state}

  def sanitize_tool_result(result, %{} = state) do
    if enabled?(state) and get_in(state, [:config, :tool_results, :enabled]) do
      sanitize_tool_result_value(result, state, nil)
    else
      {result, state}
    end
  end

  defp sanitize_tool_value(value, %{} = state, _field_name) when is_map(value) do
    Enum.reduce(value, {%{}, state}, fn {key, nested_value}, {acc, current_state} ->
      normalized_field_name = normalize_field_name(key)

      {sanitized_value, updated_state} =
        sanitize_tool_value(nested_value, current_state, normalized_field_name)

      {Map.put(acc, key, sanitized_value), updated_state}
    end)
  end

  defp sanitize_tool_value(value, %{} = state, field_name) when is_list(value) do
    Enum.map_reduce(value, state, fn nested_value, current_state ->
      sanitize_tool_value(nested_value, current_state, field_name)
    end)
  end

  defp sanitize_tool_value(value, %{} = state, field_name) when is_binary(value) do
    types = tool_field_types(field_name, state.config)
    sanitize_string(value, types, state, :tool)
  end

  defp sanitize_tool_value(value, %{} = state, _field_name), do: {value, state}

  defp sanitize_tool_result_value(value, %{} = state, _field_name) when is_map(value) do
    Enum.reduce(value, {%{}, state}, fn {key, nested_value}, {acc, current_state} ->
      normalized_field_name = normalize_field_name(key)

      {sanitized_value, updated_state} =
        sanitize_tool_result_value(nested_value, current_state, normalized_field_name)

      {Map.put(acc, key, sanitized_value), updated_state}
    end)
  end

  defp sanitize_tool_result_value(value, %{} = state, field_name) when is_list(value) do
    Enum.map_reduce(value, state, fn nested_value, current_state ->
      sanitize_tool_result_value(nested_value, current_state, field_name)
    end)
  end

  defp sanitize_tool_result_value(value, %{} = state, field_name) when is_binary(value) do
    types = tool_result_types(field_name, state.config)
    sanitize_string(value, types, state, :tool_result)
  end

  defp sanitize_tool_result_value(value, %{} = state, _field_name), do: {value, state}

  defp sanitize_string(value, [], %{} = state, _surface), do: {value, state}

  defp sanitize_string(value, types, %{} = state, _surface) do
    Enum.reduce(types, {canonicalize_string(value), state}, fn type,
                                                               {current_value, current_state} ->
      {sanitize_by_type(current_value, type, current_state.config), current_state}
    end)
  end

  defp sanitize_by_type(value, :html, config) do
    case get_in(config, [:rules, :html, :action]) do
      :strip_tags ->
        value
        |> String.replace(~r/<(script|style)\b[^>]*>.*?<\/\1>/is, " ")
        |> String.replace(~r/<!--.*?-->/s, " ")
        |> String.replace(~r/<[^>]+>/, " ")
        |> decode_basic_entities()
        |> normalize_whitespace()

      _other ->
        value
    end
  end

  defp sanitize_by_type(value, :markdown, config) do
    case get_in(config, [:rules, :markdown, :action]) do
      :plain_text ->
        value
        |> String.replace(~r/!\[([^\]]*)\]\(([^)]+)\)/u, "\\1")
        |> String.replace(~r/\[([^\]]+)\]\(([^)]+)\)/u, "\\1")
        |> String.replace(~r/```/u, "")
        |> String.replace(~r/`([^`]*)`/u, "\\1")
        |> String.replace(~r/^\s{0,3}[>#*-]+\s?/mu, "")
        |> String.replace(~r/(\*\*|__|\*|_|~~)/u, "")
        |> normalize_whitespace()

      _other ->
        value
    end
  end

  defp sanitize_by_type(value, :url, config) do
    case get_in(config, [:rules, :url, :action]) do
      :drop_unsafe ->
        allowed_schemes = get_in(config, [:rules, :url, :allowed_schemes]) || []
        sanitize_url(value, allowed_schemes)

      _other ->
        value
    end
  end

  defp sanitize_by_type(value, :filename, config) do
    case get_in(config, [:rules, :filename, :action]) do
      :basename ->
        value
        |> String.replace("\\", "/")
        |> Path.basename()
        |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
        |> String.replace(~r/[^[:alnum:]\._-]+/u, "_")
        |> String.trim("_")
        |> case do
          "" -> "file"
          sanitized -> sanitized
        end

      _other ->
        value
    end
  end

  defp sanitize_by_type(value, :shell, config) do
    case get_in(config, [:rules, :shell, :action]) do
      :neutralize ->
        value
        |> String.replace(~r/`|\$\(|\)|&&|\|\||[;&|><]/u, " ")
        |> normalize_whitespace()

      _other ->
        value
    end
  end

  defp sanitize_by_type(value, _type, _config), do: value

  defp sanitize_url(value, allowed_schemes) do
    trimmed = canonicalize_string(value)
    uri = URI.parse(trimmed)
    scheme = uri.scheme && String.downcase(uri.scheme)

    cond do
      trimmed == "" ->
        ""

      safe_relative_url?(trimmed, scheme) ->
        trimmed

      scheme in allowed_schemes ->
        uri
        |> Map.update!(:scheme, &String.downcase/1)
        |> maybe_downcase_host()
        |> URI.to_string()

      true ->
        ""
    end
  end

  defp maybe_downcase_host(%URI{host: nil} = uri), do: uri
  defp maybe_downcase_host(%URI{host: host} = uri), do: %{uri | host: String.downcase(host)}

  defp safe_relative_url?(trimmed, nil) do
    String.starts_with?(trimmed, ["/", "./", "../", "?", "#"])
  end

  defp safe_relative_url?(_trimmed, _scheme), do: false

  defp decode_basic_entities(value) do
    value
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp normalize_whitespace(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp canonicalize_string(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.normalize(:nfc)
    |> String.trim()
  end

  defp message_role(message) do
    message
    |> Map.get(:role, Map.get(message, "role", ""))
    |> to_string()
  end

  defp message_content(message) do
    Map.get(message, :content, Map.get(message, "content"))
  end

  defp put_message_content(message, content) do
    cond do
      Map.has_key?(message, :content) -> Map.put(message, :content, content)
      Map.has_key?(message, "content") -> Map.put(message, "content", content)
      true -> Map.put(message, :content, content)
    end
  end

  defp tool_field_types(nil, _config), do: []

  defp tool_field_types(field_name, config) do
    explicit =
      config
      |> get_in([:tools, :field_types])
      |> Map.get(field_name, [])

    if explicit != [] do
      explicit
    else
      if get_in(config, [:tools, :infer_fields]) do
        infer_field_types(field_name)
      else
        []
      end
    end
  end

  defp tool_result_types(nil, config) do
    get_in(config, [:tool_results, :types]) || []
  end

  defp tool_result_types(field_name, config) do
    explicit =
      config
      |> get_in([:tool_results, :field_types])
      |> Map.get(field_name, [])

    cond do
      explicit != [] ->
        explicit

      get_in(config, [:tool_results, :infer_fields]) ->
        inferred = infer_field_types(field_name)
        if inferred == [], do: get_in(config, [:tool_results, :types]) || [], else: inferred

      true ->
        get_in(config, [:tool_results, :types]) || []
    end
  end

  defp infer_field_types(field_name) do
    cond do
      field_name in ["url", "uri", "href", "link", "website", "webhook_url", "base_url"] ->
        [:url]

      field_name in ["filename", "file_name", "attachment_name", "upload_name"] ->
        [:filename]

      field_name in ["command", "cmd", "shell", "shell_command", "bash", "script"] ->
        [:shell]

      field_name in ["html", "html_content", "markup"] ->
        [:html]

      field_name in ["markdown", "markdown_content", "md"] ->
        [:markdown]

      true ->
        []
    end
  end

  defp normalize_field_name(key) when is_atom(key),
    do: key |> Atom.to_string() |> normalize_field_name()

  defp normalize_field_name(key) when is_binary(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp normalize_field_name(key), do: key |> to_string() |> normalize_field_name()

  defp resolve_config(opts) do
    global =
      Application.get_env(:synaptic, __MODULE__, [])
      |> normalize_config()

    per_call =
      opts
      |> Keyword.get(:sanitization)
      |> normalize_config()

    merge_config(global, per_call)
  end

  defp normalize_config(nil), do: %{}
  defp normalize_config(false), do: %{enabled: false}
  defp normalize_config(true), do: %{enabled: true}

  defp normalize_config(config) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "sanitization config must be a keyword list, map, boolean, or nil, got: #{inspect(config)}"
    end

    config
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(%{} = config) do
    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      prompt: normalize_prompt_config(fetch_value(config, :prompt)),
      tools: normalize_tools_config(fetch_value(config, :tools)),
      tool_results: normalize_tool_results_config(fetch_value(config, :tool_results)),
      rules: normalize_rules_config(fetch_value(config, :rules))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_config(other) do
    raise ArgumentError,
          "sanitization config must be a keyword list, map, boolean, or nil, got: #{inspect(other)}"
  end

  defp merge_config(global, per_call) do
    @default_config
    |> Map.merge(global)
    |> Map.merge(per_call)
    |> Map.put(
      :prompt,
      @default_config.prompt
      |> Map.merge(Map.get(global, :prompt, %{}))
      |> Map.merge(Map.get(per_call, :prompt, %{}))
    )
    |> Map.put(
      :tools,
      @default_config.tools
      |> Map.merge(Map.get(global, :tools, %{}))
      |> Map.merge(Map.get(per_call, :tools, %{}))
    )
    |> Map.put(
      :tool_results,
      @default_config.tool_results
      |> Map.merge(Map.get(global, :tool_results, %{}))
      |> Map.merge(Map.get(per_call, :tool_results, %{}))
    )
    |> Map.put(
      :rules,
      @default_config.rules
      |> Map.merge(Map.get(global, :rules, %{}))
      |> Map.merge(Map.get(per_call, :rules, %{}))
    )
  end

  defp normalize_prompt_config(nil), do: nil

  defp normalize_prompt_config(config) do
    config = normalize_map_or_keyword(config, "sanitization prompt config")

    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      roles: normalize_roles(fetch_value(config, :roles)),
      types: normalize_types(fetch_value(config, :types))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_tools_config(nil), do: nil

  defp normalize_tools_config(config) do
    config = normalize_map_or_keyword(config, "sanitization tools config")

    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      infer_fields: normalize_booleanish(fetch_value(config, :infer_fields)),
      field_types: normalize_field_types(fetch_value(config, :field_types))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_tool_results_config(nil), do: nil

  defp normalize_tool_results_config(config) do
    config = normalize_map_or_keyword(config, "sanitization tool_results config")

    %{
      enabled: normalize_booleanish(fetch_value(config, :enabled)),
      infer_fields: normalize_booleanish(fetch_value(config, :infer_fields)),
      field_types: normalize_field_types(fetch_value(config, :field_types)),
      types: normalize_types(fetch_value(config, :types))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_rules_config(nil), do: nil

  defp normalize_rules_config(config) do
    config = normalize_map_or_keyword(config, "sanitization rules config")

    Enum.reduce(@types, %{}, fn type, acc ->
      normalized =
        config
        |> fetch_value(type)
        |> normalize_rule(type)

      if normalized == nil, do: acc, else: Map.put(acc, type, normalized)
    end)
  end

  defp normalize_rule(nil, _type), do: nil

  defp normalize_rule(config, :url) do
    config = normalize_map_or_keyword(config, "sanitization url rule")

    %{
      action: normalize_action(fetch_value(config, :action)),
      allowed_schemes: normalize_roles(fetch_value(config, :allowed_schemes))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_rule(config, _type) do
    config = normalize_map_or_keyword(config, "sanitization rule")

    %{
      action: normalize_action(fetch_value(config, :action))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_field_types(nil), do: nil

  defp normalize_field_types(field_types) do
    field_types = normalize_map_or_keyword(field_types, "sanitization field_types")

    Enum.reduce(field_types, %{}, fn {key, value}, acc ->
      normalized_value = normalize_types(value)

      if normalized_value == [] do
        acc
      else
        Map.put(acc, normalize_field_name(key), normalized_value)
      end
    end)
  end

  defp normalize_types(nil), do: nil

  defp normalize_types(type) when is_atom(type) do
    if type in @types, do: [type], else: []
  end

  defp normalize_types(type) when is_binary(type) do
    case String.downcase(type) do
      "html" -> [:html]
      "markdown" -> [:markdown]
      "url" -> [:url]
      "filename" -> [:filename]
      "shell" -> [:shell]
      _ -> []
    end
  end

  defp normalize_types(types) when is_list(types) do
    types
    |> Enum.flat_map(&normalize_types/1)
    |> Enum.uniq()
  end

  defp normalize_types(_types), do: []

  defp normalize_roles(nil), do: nil

  defp normalize_roles(roles) when is_list(roles) do
    roles
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_roles(role) do
    [to_string(role)]
  end

  defp normalize_action(nil), do: nil

  defp normalize_action(action)
       when action in [:strip_tags, :plain_text, :drop_unsafe, :basename, :neutralize],
       do: action

  defp normalize_action(action) when is_binary(action) do
    case String.downcase(action) do
      "strip_tags" -> :strip_tags
      "plain_text" -> :plain_text
      "drop_unsafe" -> :drop_unsafe
      "basename" -> :basename
      "neutralize" -> :neutralize
      _ -> nil
    end
  end

  defp normalize_action(_action), do: nil

  defp normalize_map_or_keyword(config, label) when is_list(config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError, "#{label} must be a keyword list or map"
    end

    Enum.into(config, %{})
  end

  defp normalize_map_or_keyword(%{} = config, _label), do: config

  defp normalize_map_or_keyword(other, label) do
    raise ArgumentError, "#{label} must be a keyword list or map, got: #{inspect(other)}"
  end

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
