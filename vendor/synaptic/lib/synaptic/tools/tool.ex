defmodule Synaptic.Tools.Tool do
  @moduledoc """
  Struct describing an LLM-callable tool.
  """

  @enforce_keys [:name, :description, :schema, :handler]
  defstruct [
    :name,
    :description,
    :schema,
    :handler,
    read_only: false,
    destructive: false,
    concurrency_safe: true,
    needs_approval: false,
    data_class: :general,
    risk: nil,
    max_result_size: nil
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: map(),
          handler: (map() -> term()),
          read_only: boolean(),
          destructive: boolean(),
          concurrency_safe: boolean(),
          needs_approval: boolean(),
          data_class: atom() | String.t(),
          risk: :low | :medium | :high | :critical | nil,
          max_result_size: pos_integer() | nil
        }

  @doc """
  Builds a tool struct from a keyword list or map.
  """
  def new(%__MODULE__{} = tool), do: tool

  def new(attrs) when is_list(attrs) do
    attrs |> Enum.into(%{}) |> new()
  end

  def new(%{name: name, description: description, schema: schema, handler: handler} = attrs)
      when is_binary(name) and is_binary(description) and is_map(schema) and
             is_function(handler, 1) do
    metadata = metadata_from_attrs(attrs)

    %__MODULE__{
      name: name,
      description: description,
      schema: schema,
      handler: handler,
      read_only: metadata.read_only,
      destructive: metadata.destructive,
      concurrency_safe: metadata.concurrency_safe,
      needs_approval: metadata.needs_approval,
      data_class: metadata.data_class,
      risk: metadata.risk,
      max_result_size: metadata.max_result_size
    }
  end

  def new(other) do
    raise ArgumentError, "invalid tool definition: #{inspect(other)}"
  end

  @doc """
  Returns the policy-relevant metadata for a tool.
  """
  def metadata(%__MODULE__{} = tool) do
    %{
      read_only: tool.read_only,
      destructive: tool.destructive,
      concurrency_safe: tool.concurrency_safe,
      needs_approval: tool.needs_approval,
      data_class: normalize_data_class(tool.data_class),
      risk: normalize_risk(tool.risk, tool),
      max_result_size: tool.max_result_size
    }
  end

  @doc """
  Serializes the tool to an OpenAI-compatible payload.
  """
  def to_openai(%__MODULE__{} = tool) do
    %{
      type: "function",
      function: %{
        name: tool.name,
        description: tool.description,
        parameters: tool.schema
      }
    }
  end

  defp metadata_from_attrs(attrs) do
    tool =
      struct(__MODULE__, %{
        read_only: Map.get(attrs, :read_only, false),
        destructive: Map.get(attrs, :destructive, false),
        concurrency_safe: Map.get(attrs, :concurrency_safe, true),
        needs_approval: Map.get(attrs, :needs_approval, false),
        data_class: Map.get(attrs, :data_class, :general),
        risk: Map.get(attrs, :risk),
        max_result_size: Map.get(attrs, :max_result_size)
      })

    metadata(tool)
  end

  defp normalize_data_class(value) when is_atom(value), do: value
  defp normalize_data_class(value) when is_binary(value), do: value
  defp normalize_data_class(_value), do: :general

  defp normalize_risk(nil, %__MODULE__{destructive: true}), do: :high
  defp normalize_risk(nil, %__MODULE__{read_only: true}), do: :low
  defp normalize_risk(nil, _tool), do: :medium
  defp normalize_risk(value, _tool) when value in [:low, :medium, :high, :critical], do: value

  defp normalize_risk(value, _tool) when is_binary(value) do
    case String.downcase(value) do
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "critical" -> :critical
      _ -> :medium
    end
  end

  defp normalize_risk(_value, _tool), do: :medium
end
