defmodule RutviExercise.Models.Codex do
  @moduledoc """
  Structured single-response development adapter backed by Synaptic's local Codex CLI provider.

  Calls always use gpt-6.1-sol with medium reasoning, read-only sandboxing, no approvals,
  ephemeral sessions, and a bounded timeout. This adapter does not execute tools.
  """

  alias ExJsonSchema.{Schema, Validator}

  @model "gpt-6.1-sol"
  @reasoning_effort "medium"
  @default_timeout_ms 30_000
  @max_timeout_ms 120_000
  @allowed_options [:command_runner, :codex_bin, :cwd, :scratch_dir, :timeout_ms]
  @provider_test_options [:command_runner, :codex_bin]
  @credential_env [{"OPENAI_API_KEY", nil}, {"CODEX_API_KEY", nil}]

  @type error :: %{
          code: atom(),
          message: String.t(),
          retryable: boolean(),
          details: map()
        }

  @spec generate(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def generate(request, opts \\ [])

  def generate(request, opts) when is_map(request) and is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, messages} <- request_messages(request),
         {:ok, schema, resolved_schema} <-
           compile_schema(Map.get(request, :output_schema) || Map.get(request, "output_schema")),
         {:ok, scratch_dir} <- scratch_dir(opts),
         {:ok, schema_path} <- write_schema(scratch_dir, schema) do
      try do
        run_request(messages, resolved_schema, schema_path, scratch_dir, opts)
      after
        File.rm(schema_path)
      end
    end
  end

  def generate(_request, _opts) do
    {:error, error(:invalid_request, "Expected a request map and keyword options.", false)}
  end

  defp run_request(messages, resolved_schema, schema_path, scratch_dir, opts) do
    provider_opts =
      opts
      |> Keyword.take(@provider_test_options)
      |> Keyword.merge(
        model: @model,
        model_reasoning_effort: @reasoning_effort,
        sandbox: :read_only,
        approval_policy: :never,
        ephemeral: true,
        ignore_user_config: true,
        skip_git_repo_check: true,
        cwd: scratch_dir,
        output_schema: schema_path,
        response_format: :json_object,
        tools: [],
        timeout_ms: timeout_ms(opts),
        env: @credential_env
      )

    case Synaptic.Tools.CodexExec.chat(messages, provider_opts) do
      {:ok, output, %{usage: usage}} ->
        validate_output(output, resolved_schema, usage)

      {:ok, output} ->
        validate_output(output, resolved_schema, nil)

      {:error, reason} ->
        {:error, provider_error(reason)}
    end
  end

  defp validate_output(output, resolved_schema, usage) when is_map(output) do
    case Validator.validate(resolved_schema, output, error_formatter: false) do
      :ok ->
        {:ok,
         %{
           output: output,
           model: @model,
           reasoning_effort: @reasoning_effort,
           usage: usage
         }}

      {:error, issues} ->
        {:error,
         error(
           :schema_validation_failed,
           "Codex returned an object that does not match the requested output schema.",
           true,
           %{issues: Enum.take(issues, 8)}
         )}
    end
  end

  defp validate_output(_output, _schema, _usage) do
    {:error, error(:invalid_model_output, "Codex did not return a JSON object.", true)}
  end

  defp request_messages(request) do
    messages = Map.get(request, :messages) || Map.get(request, "messages")
    prompt = Map.get(request, :prompt) || Map.get(request, "prompt")

    cond do
      is_list(messages) and messages != [] ->
        if Enum.all?(messages, &valid_message?/1) do
          {:ok, messages}
        else
          {:error,
           error(
             :invalid_request,
             "Messages must contain only system, user, or assistant text messages.",
             false
           )}
        end

      is_binary(prompt) and String.trim(prompt) != "" ->
        {:ok, [%{role: :user, content: prompt}]}

      true ->
        {:error, error(:invalid_request, "Provide a non-empty prompt or messages list.", false)}
    end
  end

  defp valid_message?(message) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")

    role in [:system, :user, :assistant, "system", "user", "assistant"] and
      is_binary(content) and String.trim(content) != ""
  end

  defp valid_message?(_), do: false

  defp compile_schema(schema) when is_map(schema) and map_size(schema) > 0 do
    with {:ok, encoded} <- Jason.encode(schema),
         {:ok, normalized} <- Jason.decode(encoded) do
      try do
        {:ok, normalized, Schema.resolve(normalized)}
      rescue
        exception in [
          Schema.InvalidSchemaError,
          Schema.InvalidReferenceError,
          Schema.UnsupportedSchemaVersionError
        ] ->
          {:error, error(:invalid_output_schema, Exception.message(exception), false)}
      end
    else
      {:error, reason} ->
        {:error, error(:invalid_output_schema, inspect(reason), false)}
    end
  end

  defp compile_schema(_schema) do
    {:error, error(:invalid_output_schema, "A non-empty JSON Schema object is required.", false)}
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @allowed_options)) do
      case timeout_ms(opts) do
        timeout when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms ->
          :ok

        _ ->
          {:error,
           error(
             :invalid_options,
             "timeout_ms must be a positive integer no greater than #{@max_timeout_ms}.",
             false
           )}
      end
    else
      {:error,
       error(:invalid_options, "Unsupported Codex adapter option.", false, %{
         allowed_options: @allowed_options
       })}
    end
  end

  defp scratch_dir(opts) do
    dir =
      Keyword.get(opts, :scratch_dir) || Keyword.get(opts, :cwd) ||
        Path.join(System.tmp_dir!(), "rutvi-codex")

    if is_binary(dir) and Path.type(dir) == :absolute do
      case File.mkdir_p(dir) do
        :ok ->
          {:ok, dir}

        {:error, reason} ->
          {:error,
           error(:scratch_unavailable, "Could not prepare the Codex scratch directory.", false, %{
             reason: reason
           })}
      end
    else
      {:error, error(:invalid_options, "scratch_dir must be an absolute path.", false)}
    end
  end

  defp write_schema(scratch_dir, schema) do
    path = Path.join(scratch_dir, "output-schema-#{random_suffix()}.json")

    case File.write(path, Jason.encode!(schema), [:exclusive]) do
      :ok ->
        {:ok, path}

      {:error, reason} ->
        {:error,
         error(:scratch_unavailable, "Could not write the temporary output schema.", false, %{
           reason: reason
         })}
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
  end

  defp timeout_ms(opts), do: Keyword.get(opts, :timeout_ms, @default_timeout_ms)

  defp provider_error({:timeout, timeout_ms}) do
    error(:provider_timeout, "The local Codex request exceeded its timeout.", true, %{
      timeout_ms: timeout_ms
    })
  end

  defp provider_error(:codex_bin_not_found) do
    error(:provider_unavailable, "The Codex CLI executable was not found.", false)
  end

  defp provider_error({:unsupported, :codex_exec_tool_loop}) do
    error(
      :unsupported_tool_call,
      "Synaptic CodexExec does not implement a tool-call loop.",
      false
    )
  end

  defp provider_error({:codex_exec_failed, status, detail}) do
    error(:provider_error, "The local Codex provider failed.", false, %{
      reason_type: :codex_exec_failed,
      exit_status: status,
      failure_class: classify_provider_failure(detail)
    })
  end

  defp provider_error(reason) do
    error(:provider_error, "The local Codex provider failed.", false, %{
      reason_type: reason_type(reason)
    })
  end

  defp classify_provider_failure(detail) when is_map(detail) do
    message = detail |> provider_error_message() |> String.downcase()

    cond do
      String.contains?(message, "model") and
          String.contains?(message, ["not supported", "unknown model", "not available"]) ->
        :model_unavailable

      String.contains?(message, ["login", "auth", "account", "subscription"]) ->
        :authentication_unavailable

      String.contains?(message, ["model", "reasoning"]) ->
        :model_configuration_rejected

      String.contains?(message, "schema") ->
        :output_schema_rejected

      true ->
        :provider_rejected_request
    end
  end

  defp classify_provider_failure(_detail), do: :provider_rejected_request

  defp provider_error_message(%{"message" => message}) when is_binary(message), do: message
  defp provider_error_message(%{message: message}) when is_binary(message), do: message

  defp provider_error_message(%{"error" => error}) when is_map(error),
    do: provider_error_message(error)

  defp provider_error_message(%{error: error}) when is_map(error),
    do: provider_error_message(error)

  defp provider_error_message(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, decoded} when is_map(decoded) -> provider_error_message(decoded)
      _ -> message
    end
  end

  defp provider_error_message(_detail), do: ""

  defp reason_type(reason) when is_atom(reason), do: reason
  defp reason_type({reason, _detail}) when is_atom(reason), do: reason
  defp reason_type({reason, _detail, _extra}) when is_atom(reason), do: reason
  defp reason_type(_reason), do: :unknown

  defp error(code, message, retryable, details \\ %{}) do
    %{code: code, message: message, retryable: retryable, details: details}
  end
end
