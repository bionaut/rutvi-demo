defmodule Synaptic.Jev do
  @moduledoc """
  Native TypeSafe Jev client for typed judgments over shared state.

  Send all independent questions about the same state in one `evaluate/3` call.
  Jev does not generate text, invoke tools, or manage workflow policy. Low
  confidence is a successful answer; callers decide whether to act or escalate.

      questions = %{
        "intent" => Synaptic.Jev.choice("What does `message` request?", %{
          "billing" => "Help with charges or invoices",
          "other" => "Anything else"
        }),
        "refund" => Synaptic.Jev.noul("Does `message` explicitly request a refund?")
      }

      Synaptic.Jev.evaluate(%{message: "Please refund this charge."}, questions)

  Configure `:synaptic, Synaptic.Jev` or pass per-call options. Credentials default
  to `TYPESAFE_API_KEY`; the model defaults to the pinned `jev-1.13.0`.

  Options: `:api_key`, `:model`, `:endpoint`, `:finch`, `:timeout` (total HTTP
  budget, default 30,000 ms), `:receive_timeout` (15,000 ms), `:pool_timeout`
  (5,000 ms), and `:max_retries` (2 additional attempts). Retries cover transient
  transport failures and HTTP 408/429/500/502/503/504/529, with bounded backoff
  and Retry-After support. Workflow retries are a separate, outer budget.

  The `:judgment` security profile surface supports `:privacy`, `:sanitization`,
  `:security_policy`, `:egress` (surface `:jev`), `:connector_gateway`, and `:audit`.
  Supply `:run_id`, `:step_name`, and `:tenant` outside workflow steps; inside
  steps they are inherited. Chat-specific options are rejected.

  Telemetry uses `[:synaptic, :jev, :start | :stop | :exception]` and excludes
  input content and answers. Returned usage remains in TypeSafe's native terms.
  """
  alias Synaptic.{Audit, OutboundHTTP, Privacy, Sanitization, Security, SecurityPolicy}
  alias Synaptic.Jev.{Question, Result}

  @options [
    :api_key,
    :model,
    :endpoint,
    :finch,
    :timeout,
    :receive_timeout,
    :pool_timeout,
    :max_retries,
    :security_profile,
    :security_explain,
    :security_diagnostics,
    :privacy,
    :sanitization,
    :security_policy,
    :egress,
    :connector_gateway,
    :audit,
    :run_id,
    :step_name,
    :tenant,
    :workflow
  ]
  @retry_statuses [408, 429, 500, 502, 503, 504, 529]

  @doc "Defines a Choice over named options and their descriptions."
  def choice(instructions, criteria),
    do: %Question{type: :choice, instructions: instructions, criteria: criteria}

  @doc "Defines a Score over two to ten ordered descriptive levels."
  def score(instructions, criteria),
    do: %Question{type: :score, instructions: instructions, criteria: criteria}

  @doc "Defines a yes/no judgment, optionally with true/false criteria."
  def noul(instructions, criteria \\ nil),
    do: %Question{type: :noul, instructions: instructions, criteria: criteria}

  @doc false
  def option_keys, do: @options

  @spec evaluate(term(), map(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def evaluate(state, questions, opts \\ []) do
    with {:ok, opts} <- options(opts),
         {:ok, opts, security_report} <- Security.prepare_opts(:judgment, opts),
         {:ok, questions} <- Question.normalize(questions),
         {:ok, state} <- normalize_state(state) do
      metadata = %{
        model: opts[:model],
        run_id: opts[:run_id],
        step_name: opts[:step_name],
        question_count: map_size(questions),
        question_types: Enum.frequencies_by(Map.values(questions), & &1["type"])
      }

      :telemetry.span([:synaptic, :jev], metadata, fn ->
        audit = Audit.new(opts)
        audit = Audit.record(:judgment, :request_prepared, metadata, audit)
        result = prepare_and_evaluate(state, questions, opts)
        status = if match?({:ok, _}, result), do: :ok, else: :error
        audit = Audit.record(:judgment, :completed, Map.put(metadata, :status, status), audit)
        result = finalize(result, audit, security_report)
        {result, Map.merge(metadata, result_metadata(result))}
      end)
    end
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts = Application.get_env(:synaptic, __MODULE__, []) |> Keyword.merge(opts)
      unknown = Keyword.keys(opts) -- @options

      opts =
        Keyword.merge(
          [
            model: "jev-1.13.0",
            endpoint: "https://api.typesafe.ai/v1/systemone",
            finch: Synaptic.Finch,
            timeout: 30_000,
            receive_timeout: 15_000,
            pool_timeout: 5_000,
            max_retries: 2
          ],
          opts
        )

      opts =
        Enum.reduce(
          [run_id: :__run_id__, step_name: :__step_name__, tenant: :__tenant__],
          opts,
          fn {key, context_key}, acc ->
            Keyword.put_new(acc, key, Process.get({:synaptic_context, context_key}))
          end
        )

      cond do
        unknown != [] ->
          {:error, {:unsupported_jev_options, unknown}}

        not Enum.all?(
          [:timeout, :receive_timeout, :pool_timeout],
          &(is_integer(opts[&1]) and opts[&1] > 0)
        ) ->
          {:error, :invalid_jev_timeout}

        not (is_integer(opts[:max_retries]) and opts[:max_retries] >= 0) ->
          {:error, :invalid_jev_retries}

        not (is_binary(opts[:model]) and opts[:model] != "") ->
          {:error, :invalid_jev_model}

        not valid_endpoint?(opts[:endpoint]) ->
          {:error, :invalid_jev_endpoint}

        true ->
          {:ok, opts}
      end
    else
      {:error, :invalid_jev_options}
    end
  end

  defp options(_), do: {:error, :invalid_jev_options}

  defp valid_endpoint?(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo)
  end

  defp valid_endpoint?(_), do: false

  defp normalize_state(state)
       when is_binary(state) or is_list(state) or (is_map(state) and not is_struct(state)) do
    with {:ok, encoded} <- Jason.encode(state), {:ok, wire} <- Jason.decode(encoded) do
      {:ok, wire}
    else
      _ -> {:error, :invalid_jev_state}
    end
  end

  defp normalize_state(_), do: {:error, :invalid_jev_state}

  defp prepare_and_evaluate(state, questions, opts) do
    # Transform values, preserving IDs, field paths and JSON structure.
    {payload, privacy} =
      Privacy.prepare_data(%{"state" => state, "questions" => questions}, Privacy.new(opts))

    {payload, _} = Sanitization.prepare_data(payload, Sanitization.new(opts))

    with {:allow, _} <- SecurityPolicy.authorize_prompt(opts, privacy),
         :ok <- preserve_answer_space(questions, payload["questions"]),
         {:ok, questions} <- Question.normalize(payload["questions"]),
         {:ok, state} <- normalize_state(payload["state"]),
         {:ok, key} <- api_key(opts),
         {:ok, body} <- Jason.encode(%{model: opts[:model], state: state, questions: questions}),
         {:ok, response} <- request(body, key, opts, now() + opts[:timeout], 0) do
      Result.decode(response.body, response.headers, questions)
    else
      {decision, trace} when decision in [:deny, :ask] ->
        {:error, {:security_policy_failed, trace}}

      {:error, _} = error ->
        error
    end
  end

  defp preserve_answer_space(original, prepared) when is_map(prepared) do
    same? = Map.keys(original) |> MapSet.new() |> MapSet.equal?(MapSet.new(Map.keys(prepared)))

    if same? and
         Enum.all?(original, fn {id, question} ->
           other = prepared[id]

           is_map(other) and question["type"] == other["type"] and
             answer_space(question) == answer_space(other)
         end) do
      :ok
    else
      {:error, :jev_answer_space_changed_by_policy}
    end
  end

  defp preserve_answer_space(_, _), do: {:error, :jev_answer_space_changed_by_policy}

  defp answer_space(%{"type" => "score", "criteria" => criteria}) when is_list(criteria),
    do: length(criteria)

  defp answer_space(%{"criteria" => criteria}) when is_map(criteria),
    do: MapSet.new(Map.keys(criteria))

  defp answer_space(_), do: nil

  defp api_key(opts) do
    case opts[:api_key] || System.get_env("TYPESAFE_API_KEY") do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, :missing_typesafe_api_key}
    end
  end

  defp request(body, key, opts, deadline, attempt) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, :jev_timeout}
    else
      response =
        request_with_deadline(
          fn ->
            OutboundHTTP.request(
              :post,
              opts[:endpoint],
              [{"content-type", "application/json"}, {"authorization", "Bearer " <> key}],
              body,
              finch: opts[:finch],
              policy_opts: opts,
              request_options: [
                receive_timeout: min(opts[:receive_timeout], remaining),
                pool_timeout: min(opts[:pool_timeout], remaining),
                request_timeout: remaining
              ],
              context: %{
                surface: :jev,
                connector: :typesafe,
                action: :evaluate,
                run_id: opts[:run_id],
                step: opts[:step_name],
                tenant: opts[:tenant]
              }
            )
          end,
          remaining
        )

      cond do
        match?({:ok, %Finch.Response{status: 200}}, response) ->
          response

        attempt < opts[:max_retries] and retryable?(response) ->
          delay = retry_delay(response, attempt)

          if delay < deadline - now() do
            Process.sleep(delay)
            request(body, key, opts, deadline, attempt + 1)
          else
            response_error(response)
          end

        true ->
          response_error(response)
      end
    end
  end

  # Finch's request timeout is best effort and HTTP/1-only. Bound checkout,
  # preflight, and all response chunks as well, including HTTP/2 connections.
  defp request_with_deadline(fun, remaining) do
    task = Task.async(fun)

    case Task.yield(task, remaining) do
      {:ok, response} ->
        response

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :jev_timeout}
    end
  end

  defp retryable?({:ok, %{status: status}}), do: status in @retry_statuses
  defp retryable?({:error, %Mint.TransportError{}}), do: true
  defp retryable?({:error, %Finch.Error{}}), do: true
  defp retryable?(_), do: false

  defp retry_delay(response, attempt) do
    headers =
      case response do
        {:ok, %{headers: headers}} -> headers
        _ -> []
      end

    retry_after =
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(key) == "retry-after", do: parse_retry_after(value)
      end)

    retry_after || min(250 * Integer.pow(2, min(attempt, 5)), 5_000) + :rand.uniform(100)
  end

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds * 1_000

      _ ->
        parse_retry_date(value)
    end
  end

  defp parse_retry_date(value) do
    with [_, day, month, year, hour, minute, second] <-
           Regex.run(
             ~r/^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
             value
           ),
         month_index when is_integer(month_index) <-
           Enum.find_index(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), &(&1 == month)),
         {:ok, date} <-
           NaiveDateTime.new(
             String.to_integer(year),
             month_index + 1,
             String.to_integer(day),
             String.to_integer(hour),
             String.to_integer(minute),
             String.to_integer(second)
           ) do
      max(0, NaiveDateTime.diff(date, NaiveDateTime.utc_now(), :millisecond))
    else
      _ -> nil
    end
  end

  # Error bodies may echo user data. Never put them into workflow errors or telemetry.
  defp response_error({:ok, %{status: status}}), do: {:error, {:jev_http_error, status}}
  defp response_error({:error, _} = error), do: error
  defp now, do: System.monotonic_time(:millisecond)

  defp finalize({:ok, result}, audit, security_report) do
    {:ok, result, metadata} =
      {:ok, result, %{}}
      |> Audit.finalize_result(audit)
      |> Security.maybe_attach_metadata(security_report)

    {:ok, %{result | metadata: metadata}}
  end

  defp finalize(error, _audit, _report), do: error

  defp result_metadata({:ok, result}),
    do: %{status: :ok, model: result.model, usage: result.usage, request_id: result.request_id}

  defp result_metadata({:error, _}), do: %{status: :error}
end
