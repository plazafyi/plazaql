defmodule PlazaQL.GeocodingExamplesTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Compiler
  alias PlazaQL.Parser
  alias PlazaQL.TypeChecker

  @examples_path Path.join([__DIR__, "..", "..", "examples", "geocoding.pql"])

  # Every blank-line-separated chunk of the file, comments stripped. Bare
  # statements and `$$.name = ...` walkthroughs can't share one query (simple
  # and named outputs don't mix), so each chunk runs as its own query.
  defp chunks() do
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
    |> Enum.reject(&(&1 == ""))
  end

  defp compile!(source) do
    assert {:ok, ast} = Parser.parse(source), "parse failed: #{source}"
    assert {:ok, typed} = TypeChecker.check(ast), "type check failed: #{source}"
    assert {:ok, %{plans: plans}} = Compiler.compile(typed), "compile failed: #{source}"
    plans
  end

  test "every statement in examples/geocoding.pql parses, type-checks and compiles" do
    plans = Enum.flat_map(chunks(), &compile!/1)
    assert length(chunks()) >= 12

    computations = for %{computation: {type, params}} <- plans, do: {type, params}

    assert {:geocode, %{address: "1600 Pennsylvania Ave", postalcode: "20500"}} =
             Enum.find(computations, &match?({:geocode, %{address: _}}, &1))

    assert {:geocode, %{layers: "poi", boundary_gid: "osm:relation:62422"}} =
             Enum.find(computations, &match?({:geocode, %{boundary_gid: _}}, &1))

    assert {:place_lookup, %{ids: ["osm:node:21154906", "osm:relation:62422"]}} =
             List.keyfind(computations, :place_lookup, 0)

    assert {:nearest, %{point: {40.7128, -74.006}, radius: 500}} =
             List.keyfind(computations, :nearest, 0)
  end
end
