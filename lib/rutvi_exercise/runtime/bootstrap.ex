defmodule RutviExercise.Runtime.Bootstrap do
  use GenServer
  alias RutviExercise.Runtime
  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    Runtime.Tools.register(%{
      name: "read_passage",
      description: "Read an exact synthetic source passage.",
      schema:
        Runtime.Schema.object(
          %{"source_id" => Runtime.Schema.string(), "passage_id" => Runtime.Schema.string()},
          ["source_id", "passage_id"]
        ),
      handler: Runtime.ReadPassage
    })

    RutviExercise.Course.register()
    {:ok, nil}
  end
end
