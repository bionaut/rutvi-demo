defmodule RutviExercise.Workflows.Echo do
  use Synaptic.Workflow

  step :echo do
    RutviExercise.Runtime.Step.run(context.task, :echo, fn -> {:ok, %{result: context.input}} end)
  end

  commit()
end
