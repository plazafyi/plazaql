defmodule PlazaQL.MixProject do
  use Mix.Project

  @source_url "https://github.com/plazafyi/plazaql"

  def project do
    [
      app: :plazaql,
      version: "0.1.0",
      elixir: "~> 1.17",
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: "https://plaza.fyi",
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

  defp description do
    "PlazaQL, a chainable query language for OpenStreetMap data: parser, type checker, " <>
      "formatter, and a compiler to parameterized PostGIS SQL."
  end

  # The tree-sitter grammar ships with the package: the parser runs the
  # tree-sitter CLI against it (src/ holds the generated C parser).
  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Language reference" => @source_url <> "#readme",
        "Plaza" => "https://plaza.fyi"
      },
      files: ~w(lib src/grammar.json src/node-types.json src/parser.c src/tree_sitter
                grammar.js tree-sitter.json queries docs/compiler.md
                mix.exs README.md CHANGELOG.md LICENSE)
    ]
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
