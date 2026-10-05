defmodule Synaptic.JevRouter do
  @moduledoc false
  alias Synaptic.Jev

  def evaluate(_context, branches, state, opts \\ []) do
    with :ok <- validate(branches, opts) do
      indexed = Enum.with_index(branches, 1)

      criteria =
        Map.new(indexed, fn {{description, _target}, index} ->
          {"branch_#{index}", description}
        end)

      targets =
        Map.new(indexed, fn {{_description, target}, index} -> {"branch_#{index}", target} end)

      question =
        Jev.choice(
          Keyword.get(opts, :prompt, "Which branch description best matches the supplied state?"),
          criteria
        )

      client_opts = Keyword.drop(opts, [:prompt, :min_confidence, :fallback, :result_key])

      with {:ok, result} <- Jev.evaluate(state, %{"route" => question}, client_opts) do
        answer = result.answers["route"]
        minimum = Keyword.get(opts, :min_confidence, 0.6)
        selected = Map.fetch!(targets, answer.choice)
        confident? = answer.confidence >= minimum
        target = if confident?, do: selected, else: Keyword.get(opts, :fallback)

        result = %{
          result
          | metadata:
              Map.put(result.metadata, :routing, %{
                selected_target: selected,
                target: target,
                min_confidence: minimum,
                used_fallback: not confident?
              })
        }

        if target do
          {:ok, target, %{Keyword.get(opts, :result_key, :jev_result) => result}}
        else
          {:error, {:jev_low_confidence, result}}
        end
      end
    end
  end

  def validate(branches, opts) do
    minimum = Keyword.get(opts, :min_confidence, 0.6)
    fallback = Keyword.get(opts, :fallback)
    result_key = Keyword.get(opts, :result_key, :jev_result)

    cond do
      not is_list(branches) or length(branches) < 2 ->
        {:error, :invalid_jev_branches}

      not Enum.all?(branches, fn
        {description, target}
        when is_binary(description) and description != "" and is_atom(target) and
               not is_nil(target) ->
          true

        _ ->
          false
      end) ->
        {:error, :invalid_jev_branches}

      not (is_number(minimum) and minimum >= 0 and minimum <= 1) ->
        {:error, :invalid_jev_confidence}

      not is_atom(fallback) ->
        {:error, :invalid_jev_fallback}

      not (is_atom(result_key) and not is_nil(result_key)) ->
        {:error, :invalid_jev_result_key}

      true ->
        :ok
    end
  end
end
