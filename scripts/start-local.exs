provider = System.get_env("RUTVI_MODEL_PROVIDER", "codex")

adapter =
  case provider do
    "codex" ->
      RutviExercise.Models.Codex

    "deterministic" ->
      RutviExercise.Models.Deterministic

    other ->
      raise "unsupported RUTVI_MODEL_PROVIDER=#{inspect(other)}; choose codex or deterministic"
  end

Application.put_env(:rutvi_exercise, :model_adapter, adapter)
Application.put_env(:rutvi_exercise, :model, System.get_env("RUTVI_MODEL", "gpt-6.1-sol"))

Application.put_env(
  :rutvi_exercise,
  :database_path,
  System.get_env("RUTVI_DATABASE", "data/rutvi.sqlite3")
)

{:ok, _apps} = Application.ensure_all_started(:rutvi_exercise)
Process.sleep(:infinity)
