defmodule RutviExercise.Course.Role do
  use Synaptic.Workflow

  step :role do
    task = context.task

    with {:ok, prepared} <- prepare(task) do
      RutviExercise.Runtime.Step.run(task, :role, fn ->
        delegation =
          if task.service_id == "course.author",
            do:
              RutviExercise.Course.Workflow.child(
                task,
                "course.research",
                %{},
                "additional-research"
              ),
            else: {:ok, %{}}

        with {:ok, _} <- delegation,
             {:ok, result} <-
               RutviExercise.Runtime.Model.generate(
                 prepared,
                 :role,
                 RutviExercise.Course.prompt(task.service_id),
                 RutviExercise.Course.schema(task.service_id),
                 %{
                   sources: RutviExercise.Course.Sources.all(),
                   output_validator: fn output ->
                     RutviExercise.Course.validate(task.service_id, output, prepared.input)
                   end
                 }
               ) do
          result =
            if task.service_id == "course.plan",
              do:
                result
                |> Map.put("audience", prepared.input["audience"])
                |> Map.put("style", prepared.input["style"]),
              else: result

          {:ok, %{result: result}}
        end
      end)
    end
  end

  commit()

  defp prepare(%{service_id: "course.plan"} = task) do
    alias RutviExercise.Runtime
    alias RutviExercise.Runtime.Schema

    audience =
      case task.input["audience"] do
        value when is_binary(value) and byte_size(value) > 0 ->
          {:ok, value}

        _ ->
          case Runtime.checkpoint(
                 task.task_id,
                 task.attempt,
                 :audience,
                 "Pro koho je kurz?",
                 Schema.object(%{"audience" => Schema.string()}, ["audience"])
               ) do
            {:ok, payload} -> {:ok, payload["audience"]}
            {:waiting, _} -> {:error, :waiting_for_human}
            error -> error
          end
      end

    with {:ok, audience} <- audience do
      style =
        if task.input["ask_style"] do
          case Runtime.checkpoint(
                 task.task_id,
                 task.attempt,
                 :style,
                 "Vyberte styl.",
                 Schema.object(%{"style" => %{"enum" => ["practical", "conceptual"]}}, ["style"])
               ) do
            {:ok, payload} -> {:ok, payload["style"]}
            {:waiting, _} -> {:error, :waiting_for_human}
            error -> error
          end
        else
          {:ok, task.input["style"] || "practical"}
        end

      with {:ok, selected_style} <- style,
           do:
             {:ok,
              %{
                task
                | input:
                    task.input
                    |> Map.put("audience", audience)
                    |> Map.put("style", selected_style)
              }}
    end
  end

  defp prepare(task), do: {:ok, task}
end
