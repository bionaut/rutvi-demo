import Config

config :rutvi_exercise,
  database_path: System.get_env("RUTVI_DATABASE", "data/rutvi.sqlite3"),
  model_adapter: RutviExercise.Models.Codex,
  model: "gpt-6.1-sol",
  reasoning_effort: "medium",
  retry_delay_ms: 25

import_config "#{config_env()}.exs"
