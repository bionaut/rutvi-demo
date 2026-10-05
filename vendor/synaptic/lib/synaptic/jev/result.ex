defmodule Synaptic.Jev.ChoiceAnswer do
  @moduledoc "A Jev Choice answer, preserving the full distribution and provider confidence."
  @enforce_keys [:choice, :probabilities, :confidence]
  @derive Jason.Encoder
  defstruct [:choice, :probabilities, :confidence]
  @type t :: %__MODULE__{choice: String.t(), probabilities: map(), confidence: number()}
end

defmodule Synaptic.Jev.ScoreAnswer do
  @moduledoc "A Jev expected rubric score, with its legend, distribution, and confidence."
  @enforce_keys [:score, :probabilities, :confidence, :legend]
  @derive Jason.Encoder
  defstruct [:score, :probabilities, :confidence, :legend]

  @type t :: %__MODULE__{
          score: number(),
          probabilities: map(),
          confidence: number(),
          legend: map()
        }
end

defmodule Synaptic.Jev.NoulAnswer do
  @moduledoc "The probability of a true answer. Noul has no separate confidence field."
  @enforce_keys [:noul]
  @derive Jason.Encoder
  defstruct [:noul]
  @type t :: %__MODULE__{noul: number()}
end

defmodule Synaptic.Jev.Result do
  @moduledoc """
  All answers to one Jev evaluation, keyed by the original string question IDs.
  `model` is the returned model ID; missing usage counts remain unknown (`nil`).
  `metadata` contains optional Synaptic security and audit reports.
  """
  alias Synaptic.Jev.{ChoiceAnswer, NoulAnswer, ScoreAnswer}
  @enforce_keys [:answers, :model]
  @derive Jason.Encoder
  defstruct [:answers, :model, :request_id, usage: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          answers: map(),
          model: String.t(),
          request_id: String.t() | nil,
          usage: map(),
          metadata: map()
        }

  @doc false
  def decode(body, headers, questions) do
    with {:ok, %{"model" => model, "answers" => answers, "usage" => usage}} <- Jason.decode(body),
         true <- is_binary(model) and model != "" and is_map(answers),
         true <- Enum.sort(Map.keys(answers)) == Enum.sort(Map.keys(questions)),
         true <- valid_usage?(usage),
         {:ok, typed} <- decode_answers(answers, questions) do
      {:ok,
       %__MODULE__{
         model: model,
         answers: typed,
         request_id:
           Enum.find_value(headers, fn {key, value} ->
             if String.downcase(key) == "x-typesafe-request-id", do: value
           end),
         usage: %{input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"]}
       }}
    else
      _ -> {:error, :invalid_jev_response}
    end
  end

  defp decode_answers(answers, questions) do
    Enum.reduce_while(answers, {:ok, %{}}, fn {id, answer}, {:ok, acc} ->
      case decode_answer(answer, questions[id]) do
        {:ok, typed} -> {:cont, {:ok, Map.put(acc, id, typed)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp decode_answer(
         %{
           "type" => "choice",
           "choice" => choice,
           "confidence" => confidence,
           "probabilities" => probabilities
         },
         %{"type" => "choice", "criteria" => criteria}
       ) do
    if Map.has_key?(criteria, choice) and probability?(confidence) and
         distribution?(probabilities, Map.keys(criteria)) do
      {:ok, %ChoiceAnswer{choice: choice, confidence: confidence, probabilities: probabilities}}
    else
      :error
    end
  end

  defp decode_answer(
         %{
           "type" => "score",
           "score" => score,
           "confidence" => confidence,
           "probabilities" => probabilities,
           "legend" => legend
         },
         %{"type" => "score", "criteria" => criteria}
       ) do
    expected_legend =
      criteria |> Enum.with_index() |> Map.new(fn {value, index} -> {to_string(index), value} end)

    if is_number(score) and score >= 0 and score <= length(criteria) - 1 and
         probability?(confidence) and legend == expected_legend and
         distribution?(probabilities, Map.keys(expected_legend)) do
      {:ok,
       %ScoreAnswer{
         score: score,
         confidence: confidence,
         probabilities: probabilities,
         legend: legend
       }}
    else
      :error
    end
  end

  defp decode_answer(%{"type" => "noul", "noul" => noul}, %{"type" => "noul"}) do
    if probability?(noul), do: {:ok, %NoulAnswer{noul: noul}}, else: :error
  end

  defp decode_answer(_, _), do: :error

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  defp distribution?(values, keys) when is_map(values) do
    Enum.sort(Map.keys(values)) == Enum.sort(keys) and
      Enum.all?(Map.values(values), &probability?/1) and
      abs(Enum.sum(Map.values(values)) - 1.0) <= 0.001
  end

  defp distribution?(_, _), do: false

  defp valid_usage?(usage) when is_map(usage) do
    Enum.all?(["input_tokens", "output_tokens"], fn key ->
      is_nil(usage[key]) or (is_integer(usage[key]) and usage[key] >= 0)
    end)
  end

  defp valid_usage?(_), do: false
end
