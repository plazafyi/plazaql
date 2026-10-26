defmodule PlazaQL.ExamplesCompileTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Compiler
  alias PlazaQL.Parser
  alias PlazaQL.TypeChecker

  @examples_dir Path.join([__DIR__, "..", "..", "examples"])
  @example_files Path.wildcard(Path.join(@examples_dir, "*.pql")) |> Enum.sort()

  # Every blank-line-separated chunk of a file, comments stripped. Bare
  # statements and `$$.name = ...` walkthroughs can't share one query (simple
  # and named outputs don't mix), so each chunk runs as its own query.
  defp chunks(path) do
    path
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

  test "the examples directory is not empty" do
    assert length(@example_files) >= 11
  end

  for path <- @example_files do
    name = Path.basename(path)

    test "examples/#{name}: every chunk parses, type-checks and compiles" do
      chunks = chunks(unquote(path))
      assert chunks != []

      for source <- chunks do
        assert {:ok, ast} = Parser.parse(source), "parse failed in #{unquote(name)}:\n#{source}"

        assert {:ok, typed} = TypeChecker.check(ast),
               "type check failed in #{unquote(name)}:\n#{source}"

        assert {:ok, _} = Compiler.compile(typed),
               "compile failed in #{unquote(name)}:\n#{source}"
      end
    end
  end
end
