defmodule RutviExercise.Models.Deterministic do
  @moduledoc "Offline fixtures depend on role, lesson and revision; scheduling order never selects a response."
  def generate(request, _opts \\ []) do
    input =
      case Enum.at(request.messages, 1) do
        %{content: text} -> Jason.decode!(text)
        _ -> %{}
      end

    delay = input["delay_ms"] || 0
    Process.sleep(delay)

    if request.role == "course.research" and request.turn == 0 do
      calls =
        Enum.map(RutviExercise.Course.Sources.all(), fn p ->
          %{
            call_id: p["source_id"],
            name: "read_passage",
            arguments: Map.take(p, ["source_id", "passage_id"])
          }
        end)

      {:ok, %{tool_calls: calls, model: "deterministic"}}
    else
      output =
        case request.role do
          "course.research" ->
            %{"passages" => RutviExercise.Course.Sources.all()}

          "course.plan" ->
            %{
              "objectives" => [
                %{"id" => "O1", "text" => "Rozlišit událost a příkaz"},
                %{"id" => "O2", "text" => "Vysvětlit duplicity a obnovu"}
              ],
              "outline" => [
                %{"lesson_id" => "L1", "objective_id" => "O1"},
                %{"lesson_id" => "L2", "objective_id" => "O2"}
              ]
            }

          "course.author" ->
            id = input["lesson_id"]
            revision = input["revision"] || 0

            text =
              cond do
                id == "L1" ->
                  "Událost popisuje nastalou skutečnost, zatímco příkaz žádá akci. Producent nemusí znát všechny konzumenty. Doručení alespoň jednou připouští duplicity a potvrzení přijetí není důkazem dokončení obchodní operace."

                revision == 0 ->
                  "Retry vždy zaručí právě jeden externí účinek."

                true ->
                  "Idempotentní zpracování neopakuje obchodní účinek. Identifikátor události a změna dat patří do jedné transakce. Dočasné chyby opakujeme s prodlevou a konečným limitem; uložené výsledky přeskočí hotové kroky. Nezávislé úlohy běží souběžně s limitem. Po pádu může být výsledek externího požadavku neznámý; bez idempotence či dotazu na stav retry nezaručuje právě jeden externí účinek."
              end

            ids =
              if id == "L1",
                do: ["S1", "S2"],
                else: if(revision == 0, do: ["S6"], else: ["S3", "S4", "S5", "S6"])

            %{
              "questions" =>
                Enum.filter(
                  questions(),
                  &(&1["objective_id"] == if(id == "L1", do: "O1", else: "O2"))
                ),
              "lesson" => %{
                "id" => id,
                "objective_id" => if(id == "L1", do: "O1", else: "O2"),
                "text" => text,
                "revision" => revision,
                "citations" => citations(ids)
              }
            }

          "course.review" ->
            rejected =
              Enum.filter(input["lessons"], fn lesson ->
                input["always_revise"] || String.contains?(lesson["text"], "Retry vždy")
              end)

            %{
              "decision" => if(rejected == [], do: "accept", else: "revise"),
              "lesson_ids" => Enum.map(rejected, & &1["id"]),
              "defects" =>
                if(rejected == [],
                  do: [],
                  else: ["Nepodložená záruka právě jednoho externího účinku."]
                )
            }
        end

      {:ok, %{output: output, model: "deterministic", usage: %{requests: 1}}}
    end
  end

  defp questions,
    do: [
      %{
        "id" => "Q1",
        "objective_id" => "O1",
        "question" => "Co popisuje událost?",
        "answer" => "Nastalou skutečnost.",
        "explanation" => "Příkaz naopak požaduje akci.",
        "citations" => RutviExercise.Models.Deterministic.citations(["S1"])
      },
      %{
        "id" => "Q2",
        "objective_id" => "O2",
        "question" => "Proč potřebujeme idempotenci?",
        "answer" => "Doručení může přinést duplicity.",
        "explanation" => "Opakované zpracování nemá opakovat obchodní účinek.",
        "citations" => RutviExercise.Models.Deterministic.citations(["S2", "S3"])
      },
      %{
        "id" => "Q3",
        "objective_id" => "O2",
        "question" => "Zaručuje retry právě jeden externí účinek?",
        "answer" => "Ne.",
        "explanation" =>
          "Po pádu může být výsledek neznámý; potřebujeme idempotenci nebo dotaz na stav.",
        "citations" => RutviExercise.Models.Deterministic.citations(["S6"])
      }
    ]

  def citations(ids), do: Enum.map(ids, &%{"source_id" => &1, "passage_id" => "P1"})
end
