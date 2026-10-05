defmodule Synaptic.Voice.TurnRouter do
  @moduledoc """
  Normalizes application-owned routing decisions for speech received while an
  orchestrated voice workflow is busy.

  The application may provide a one-argument function, a module implementing
  `classify/1`, or an MFA tuple. Synaptic owns the single-flight state machine;
  the application only decides what the new utterance means.
  """

  @actions [:continue, :replace, :enqueue, :cancel, :ambiguous, :confirm, :decline]

  @type action ::
          :continue | :replace | :enqueue | :cancel | :ambiguous | :confirm | :decline

  @type decision :: %{
          required(:action) => action(),
          optional(:request) => String.t() | nil,
          optional(:acknowledgement) => String.t() | nil
        }

  @spec classify(term(), map()) :: {:ok, decision()} | {:error, term()}
  def classify(nil, context), do: {:ok, fallback(context)}

  def classify(router, context) when is_map(context) do
    router
    |> invoke(context)
    |> normalize(context)
  rescue
    error -> {:error, {:turn_router_exception, error}}
  catch
    kind, reason -> {:error, {:turn_router_failure, kind, reason}}
  end

  defp invoke(router, context) when is_function(router, 1), do: router.(context)

  defp invoke({module, function, arguments}, context)
       when is_atom(module) and is_atom(function) and is_list(arguments) do
    apply(module, function, [context | arguments])
  end

  defp invoke(module, context) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :classify, 1) do
      module.classify(context)
    else
      {:error, {:invalid_turn_router, module}}
    end
  end

  defp invoke(other, _context), do: {:error, {:invalid_turn_router, other}}

  defp normalize({:ok, decision}, context), do: normalize(decision, context)
  defp normalize({:error, _reason} = error, _context), do: error

  defp normalize(decision, _context) when is_map(decision) do
    with {:ok, action} <-
           normalize_action(Map.get(decision, :action) || Map.get(decision, "action")) do
      {:ok,
       %{
         action: action,
         request: normalize_text(Map.get(decision, :request) || Map.get(decision, "request")),
         acknowledgement:
           normalize_text(
             Map.get(decision, :acknowledgement) || Map.get(decision, "acknowledgement")
           )
       }}
    end
  end

  defp normalize(_decision, _context), do: {:error, :invalid_turn_routing_decision}

  defp normalize_action(action) when action in @actions, do: {:ok, action}

  defp normalize_action(action) when is_binary(action) do
    normalized = action |> String.trim() |> String.downcase()

    case Enum.find(@actions, &(Atom.to_string(&1) == normalized)) do
      nil -> {:error, {:invalid_turn_routing_action, action}}
      value -> {:ok, value}
    end
  end

  defp normalize_action(action), do: {:error, {:invalid_turn_routing_action, action}}

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> String.slice(text, 0, 500)
    end
  end

  defp normalize_text(_value), do: nil

  defp fallback(context) do
    %{
      action: :ambiguous,
      request: normalize_text(Map.get(context, :utterance) || Map.get(context, "utterance")),
      acknowledgement: nil
    }
  end
end
