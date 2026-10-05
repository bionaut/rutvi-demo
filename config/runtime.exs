import Config

default_provider = if config_env() == :test, do: "deterministic", else: "codex"
provider = System.get_env("RUTVI_MODEL_PROVIDER", default_provider)

model_adapter =
  case provider do
    "codex" ->
      RutviExercise.Models.Codex

    "remote_codex" ->
      RutviExercise.Models.RemoteCodex

    "deterministic" ->
      RutviExercise.Models.Deterministic

    other ->
      raise "unsupported RUTVI_MODEL_PROVIDER=#{inspect(other)}; choose codex, remote_codex or deterministic"
  end

model = System.get_env("RUTVI_MODEL", "gpt-6.1-sol")

model_defaults =
  case System.get_env("RUTVI_MODEL_PROFILE", "strict") do
    "strict" ->
      %{}

    "codex_local" ->
      %{timeout_ms: 90_000, tool_timeout_ms: 5_000, profile: "codex_local"}

    other ->
      raise "unsupported RUTVI_MODEL_PROFILE=#{inspect(other)}; choose strict or codex_local"
  end

default_database =
  if config_env() == :test,
    do:
      Path.join(
        System.tmp_dir!(),
        "rutvi-test-#{System.pid()}-#{System.system_time(:nanosecond)}.sqlite3"
      ),
    else: "data/rutvi.sqlite3"

database_path = System.get_env("RUTVI_DATABASE", default_database)

config :rutvi_exercise,
  database_path: database_path,
  model_adapter: model_adapter,
  model: model,
  model_defaults: model_defaults

studio_secret =
  System.get_env("RUTVI_STUDIO_SECRET") || Base.encode64(:crypto.strong_rand_bytes(64))

if byte_size(studio_secret) < 64,
  do: raise("RUTVI_STUDIO_SECRET must contain at least 64 characters")

config :rutvi_exercise,
  studio_demo: System.get_env("RUTVI_STUDIO_DEMO", "false") == "true",
  studio_namespace: System.get_env("RUTVI_STUDIO_NAMESPACE", "A"),
  studio_secret: studio_secret
