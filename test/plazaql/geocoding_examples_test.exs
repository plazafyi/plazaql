defmodule PlazaQL.GeocodingExamplesTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Compiler
  alias PlazaQL.Parser
  alias PlazaQL.TypeChecker

  @examples_path Path.join([__DIR__, "..", "..", "examples", "geocoding.pql"])

  # The file's bare geocoding statements, one per blank-line-separated
  # chunk. The `$$.name = ...` walkthroughs build on each other, and the
  # `nearest(point, amenity: ...)` example uses a tag keyword the compiler
  # does not accept yet, so neither is checked here.
  defp bare_statements() do
    @examples_path
    |> File.read!()
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(fn chunk ->
      chunk
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "//"))
      |> Enum.join("\n")
      |> String.trim()
    end)
    |> Enum.filter(
      &Regex.match?(~r/^(geocode|place_lookup|autocomplete|reverse_geocode|text_search)\(/, &1)
    )
  end

  defp compile!(source) do
    {:ok, ast} = Parser.parse(source)
    assert {:ok, typed} = TypeChecker.check(ast), "type check failed: #{source}"
    assert {:ok, %{plans: [plan]}} = Compiler.compile(typed), "compile failed: #{source}"
    plan.computation
  end

  test "examples/geocoding.pql statements parse, type-check and compile" do
    computations = Enum.map(bare_statements(), &compile!/1)

    assert {:geocode, %{address: "1600 Pennsylvania Ave", postalcode: "20500"}} =
             Enum.find(computations, &match?({:geocode, %{address: _}}, &1))

    assert {:geocode, %{layers: "poi", boundary_gid: "osm:relation:62422"}} =
             Enum.find(computations, &match?({:geocode, %{boundary_gid: _}}, &1))

    assert {:place_lookup, %{ids: ["osm:node:21154906", "osm:relation:62422"]}} =
             List.keyfind(computations, :place_lookup, 0)
  end
end
