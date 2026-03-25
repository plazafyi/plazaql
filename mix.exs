defmodule PlazaQL.MixProject do
  use Mix.Project

  def project do
    [
      app: :plazaql,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      elixirc_options: [warnings_as_errors: true],
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        flags: [
          :unmatched_returns,
          :error_handling,
          :extra_return,
          :missing_return,
          :underspecs
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [check: :dev]
    ]
  end

  def application do
    [extra_applications: [:logger, :xmerl]]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      check: [
        "format",
        "credo --strict",
        "cmd biome check --write ."
      ],
      precommit: ["cmd prek run --all-files"]
    ]
  end
end
