defmodule RutviExercise.Course.Workflow do
  use Synaptic.Workflow
  alias RutviExercise.{Runtime, Store, Runtime.Step}

  step :course do
    run(context.task)
  end

  commit()

  def run(task) do
    with {:ok, _research} <- child(task, "course.research", %{}, "research"),
         {:ok, plan} <-
           child(
             task,
             "course.plan",
             Map.take(task.input, ["audience", "ask_style", "style"]),
             "plan"
           ),
         {:ok, lessons} <- lessons(task, plan, 0, ["L1", "L2"], %{}, []),
         {:ok, result} <- review(task, plan["audience"], plan, lessons, 0) do
      {:ok, %{result: result}}
    end
  end

  def child(task, service, payload, key),
    do:
      Runtime.delegate(task, service, payload, key,
        context_pack: %{source_ids: ["S1", "S2", "S3", "S4", "S5", "S6"]}
      )

  defp lessons(task, plan, revision, ids, existing, feedback) do
    tasks =
      Enum.map(ids, fn id ->
        Task.Supervisor.async_nolink(RutviExercise.DomainWorkers, fn ->
          Step.run(task, {:lesson, id, revision}, fn ->
            with {:ok, result} <-
                   child(
                     task,
                     "course.author",
                     %{
                       "lesson_id" => id,
                       "revision" => revision,
                       "audience" => plan["audience"],
                       "plan" => plan,
                       "reviewer_feedback" => feedback,
                       "delay_ms" => task.input["delay_ms"] || 0
                     },
                     "#{id}:#{revision}"
                   ),
                 do: {:ok, Map.put(result["lesson"], "questions", result["questions"])}
          end)
        end)
      end)

    results = Enum.zip(ids, Task.await_many(tasks, :infinity))

    Enum.reduce_while(results, {:ok, existing}, fn
      {id, {:ok, lesson}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, id, lesson)}}
      {_, error}, _ -> {:halt, error}
    end)
  end

  defp review(task, audience, plan, lessons, revision) do
    payload = %{
      "lessons" => Enum.map(["L1", "L2"], &Map.delete(lessons[&1], "questions")),
      "always_revise" => task.input["always_revise"] || false,
      "plan" => plan,
      "questions" => Enum.flat_map(["L1", "L2"], &(lessons[&1]["questions"] || []))
    }

    with {:ok, review} <- child(task, "course.review", payload, "review:#{revision}") do
      case review["decision"] do
        "accept" ->
          {:ok, artifact(audience, plan, lessons)}

        "revise" when revision < 2 ->
          ids = review["lesson_ids"]

          if Enum.all?(ids, &(&1 in ["L1", "L2"])) and ids != [] do
            Store.transact(fn data ->
              t = data.tasks[task.task_id]

              {:ok,
               Runtime.put_task(data, %{t | revision: revision + 1}, :revision, %{
                 revision: revision + 1,
                 lesson_ids: ids
               })}
            end)

            with {:ok, lessons} <-
                   lessons(task, plan, revision + 1, ids, lessons, review["defects"]),
                 do: review(task, audience, plan, lessons, revision + 1)
          else
            {:error, :invalid_route}
          end

        "revise" ->
          result = Map.put(artifact(audience, plan, lessons), "review", review)
          RutviExercise.Runtime.Dispatcher.finish(task, :needs_review, result, :revision_limit)
          {:error, :needs_review}

        _ ->
          {:error, :invalid_route}
      end
    end
  end

  defp artifact(audience, plan, lessons) do
    %{
      "title" => "Základy událostmi řízených systémů",
      "audience" => audience,
      "objectives" => plan["objectives"],
      "outline" => plan["outline"],
      "lessons" => Enum.map(["L1", "L2"], &Map.delete(lessons[&1], "questions")),
      "questions" => Enum.flat_map(["L1", "L2"], &(lessons[&1]["questions"] || []))
    }
  end
end
