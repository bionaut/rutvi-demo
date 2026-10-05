defmodule RutviExercise.Course.Sources do
  @sources %{
    "S1" =>
      "Událost popisuje nastalou skutečnost; příkaz požaduje akci. Producent nemusí znát všechny konzumenty.",
    "S2" =>
      "Doručení alespoň jednou připouští duplicity. Potvrzení přijetí neprokazuje dokončení obchodní operace.",
    "S3" =>
      "Opakované zpracování stejné události nemá opakovat obchodní účinek. Identifikátor události a změnu dat lze uložit jednou transakcí; oddělené zápisy mohou při pádu zanechat nekonzistenci.",
    "S4" =>
      "Dočasné chyby opakujte s prodlevou a konečným limitem. Uložené výsledky umožní přeskočit dokončené kroky; restart procesu neobnoví ztracenou paměť.",
    "S5" =>
      "Nezávislé úlohy mohou běžet souběžně s limitem chránícím navazující služby. Pořadí dokončení není zaručeno; závislý krok čeká na potřebné výsledky.",
    "S6" =>
      "Pád po přijetí požadavku externí službou, ale před uložením odpovědi může zanechat neznámý výsledek. Bez idempotence či dotazu na stav retry obecně nezaručuje právě jeden externí účinek."
  }
  def read(id, "P1") do
    case Map.fetch(@sources, id) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, :not_found}
    end
  end

  def read(_, _), do: {:error, :not_found}

  def all,
    do:
      Enum.map(Enum.sort(@sources), fn {id, text} ->
        %{"source_id" => id, "passage_id" => "P1", "text" => text}
      end)
end
