import Config

config :rutvi_exercise,
  database_path:
    Path.join(
      System.tmp_dir!(),
      "rutvi-test-#{System.pid()}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}.sqlite3"
    ),
  model_adapter: RutviExercise.Models.Deterministic

config :logger, level: :warning

config :rutvi_exercise, http_enabled: false
