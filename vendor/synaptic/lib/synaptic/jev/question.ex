defmodule Synaptic.Jev.Question do
  @moduledoc """
  A typed Jev question. Construct questions with `Synaptic.Jev.choice/2`,
  `Synaptic.Jev.score/2`, or `Synaptic.Jev.noul/2`.

  Instructions and criterion descriptions retain their JSON structure. Question
  IDs and Choice labels are strings; they are never converted to atoms.
  """
  @enforce_keys [:type, :instructions]
  defstruct [:type, :instructions, :criteria]

  @type t :: %__MODULE__{type: :choice | :score | :noul, instructions: term(), criteria: term()}

  @doc false
  def normalize(questions)
      when is_map(questions) and not is_struct(questions) and map_size(questions) > 0 do
    Enum.reduce_while(questions, {:ok, %{}}, fn {id, question}, {:ok, acc} ->
      with true <- is_binary(id) and id != "",
           {:ok, question} <- normalize_question(question) do
        {:cont, {:ok, Map.put(acc, id, question)}}
      else
        _ -> {:halt, {:error, {:invalid_question, id}}}
      end
    end)
  end

  def normalize(_), do: {:error, :invalid_questions}

  defp normalize_question(%__MODULE__{type: type} = question)
       when type in [:choice, :score, :noul] do
    question
    |> Map.from_struct()
    |> Map.update!(:type, &to_string/1)
    |> normalize_question()
  end

  defp normalize_question(question) when is_map(question) and not is_struct(question) do
    with {:ok, json} <- Jason.encode(question),
         {:ok, wire} <- Jason.decode(json),
         true <- Map.has_key?(wire, "instructions") and entry?(wire["instructions"]),
         true <- valid_criteria?(wire["type"], wire["criteria"]),
         true <- Enum.all?(Map.keys(wire), &(&1 in ["type", "instructions", "criteria"])) do
      {:ok, if(is_nil(wire["criteria"]), do: Map.delete(wire, "criteria"), else: wire)}
    else
      _ -> {:error, :invalid_question}
    end
  end

  defp normalize_question(_), do: {:error, :invalid_question}

  defp valid_criteria?("choice", criteria) when is_map(criteria) and map_size(criteria) >= 2 do
    Enum.all?(criteria, fn {key, value} -> is_binary(key) and key != "" and entry?(value) end)
  end

  defp valid_criteria?("score", criteria) when is_list(criteria),
    do: length(criteria) in 2..10 and Enum.all?(criteria, &entry?/1)

  defp valid_criteria?("noul", nil), do: true

  defp valid_criteria?("noul", criteria) when is_map(criteria) do
    Enum.all?(Map.keys(criteria), &(&1 in ["false", "true"])) and
      Enum.all?(Map.values(criteria), &entry?/1)
  end

  defp valid_criteria?(_, _), do: false

  defp entry?(value), do: is_nil(value) or is_binary(value) or is_map(value) or is_list(value)
end
