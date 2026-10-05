defmodule RutviExercise.MixProject do
  use Mix.Project

  def project do
    [
      app: :rutvi_exercise,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {RutviExercise.Application, []},
      extra_applications: [:logger, :crypto, :inets, :ssl]
    ]
  end

  defp deps do
    [
      {:synaptic, path: "vendor/synaptic"},
      {:exqlite, "~> 0.30"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"}
    ]
  end
end
