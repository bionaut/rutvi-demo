defmodule RutviExercise.Runtime.Tools do
  @moduledoc "Code-registered tool handlers; model data selects names and arguments, never executable code."
  alias RutviExercise.{Store, Runtime.Schema}

  def register(definition) do
    if is_binary(definition[:name]) and is_binary(definition[:description]) and
         is_map(definition[:schema]) and is_atom(definition[:handler]) and
         not is_nil(definition[:handler]) do
      Store.transact(fn data ->
        tools = Map.get(data, :tools, %{})

        case tools[definition.name] do
          nil ->
            {{:ok, definition},
             Map.put(data, :tools, Map.put(tools, definition.name, definition))}

          ^definition ->
            {{:ok, definition}, data}

          _ ->
            {{:error, :conflict}, data}
        end
      end)
    else
      {:error, :validation_error}
    end
  end

  def definitions(names),
    do:
      Store.read(fn data ->
        Enum.flat_map(names, fn name ->
          case Map.get(data, :tools, %{})[name] do
            nil -> []
            tool -> [Map.drop(tool, [:handler])]
          end
        end)
      end)

  def invoke(name, args, task) do
    case Store.read(&Map.get(&1, :tools, %{})[name]) do
      nil -> {:error, :not_found}
      tool -> with :ok <- Schema.validate(args, tool.schema), do: tool.handler.call(args, task)
    end
  end
end

defmodule RutviExercise.Runtime.ReadPassage do
  def call(args, _task),
    do: RutviExercise.Course.Sources.read(args["source_id"], args["passage_id"])
end
