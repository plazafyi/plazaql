defmodule PlazaQL.ReadmeTest do
  @moduledoc """
  Drift prevention: ensures all PlazaQL code examples in README.md parse without errors.

  If grammar.js changes and README examples become invalid, this test fails.
  """
  use ExUnit.Case, async: true

  alias PlazaQL.Parser

  @readme_path Path.join([__DIR__, "..", "..", "README.md"])

  # Extract all ```plazaql code blocks from README.md
  @plazaql_blocks (fn ->
                     readme = File.read!(@readme_path)
                     lines = String.split(readme, "\n")

                     lines
                     |> Enum.reduce({[], false, []}, fn
                       "```plazaql" <> _, {blocks, false, _current} ->
                         {blocks, true, []}

                       "```" <> _, {blocks, true, current} ->
                         block =
                           current
                           |> Enum.reverse()
                           |> Enum.join("\n")

                         {[block | blocks], false, []}

                       line, {blocks, true, current} ->
                         {blocks, true, [line | current]}

                       _line, acc ->
                         acc
                     end)
                     |> elem(0)
                     |> Enum.reverse()
                   end).()

  describe "README.md examples" do
    for {block, idx} <- Enum.with_index(@plazaql_blocks, 1) do
      first_line =
        block
        |> String.split("\n")
        |> Enum.find(&(String.trim(&1) != "" && !String.starts_with?(String.trim(&1), "//")))
        |> then(&(&1 || "block #{idx}"))
        |> String.trim()
        |> String.slice(0, 60)

      @block block
      test "block #{idx}: #{first_line}" do
        block = @block
        source = wrap_for_parsing(block)

        case Parser.parse(source) do
          {:ok, _ast} ->
            :ok

          {:error, errors} ->
            flunk("""
            README example failed to parse (block #{unquote(idx)}):

            Source:
            #{source}

            Errors:
            #{Enum.map_join(errors, "\n", &inspect/1)}
            """)
        end
      end
    end
  end

  # Wrap README code blocks so they parse as valid PQL programs.
  # Closing delimiters go on new lines so // line comments don't swallow them.
  defp wrap_for_parsing(block) do
    trimmed = String.trim(block)

    cond do
      String.starts_with?(trimmed, ".") ->
        wrap_method_chain(trimmed)

      tag_filter_fragment?(trimmed) ->
        wrap_tag_filters(trimmed)

      expression_fragment?(trimmed) ->
        wrap_expressions(trimmed)

      comment_only?(trimmed) ->
        trimmed

      multiline_without_semicolons?(trimmed) ->
        wrap_multiline(trimmed)

      not String.contains?(trimmed, ";") ->
        trimmed <> "\n;"

      true ->
        trimmed
    end
  end

  defp wrap_method_chain(trimmed), do: "search(node, amenity: \"cafe\")\n  #{trimmed}\n;"

  defp wrap_tag_filters(trimmed) do
    trimmed
    |> code_lines()
    |> Enum.map_join("\n", fn line ->
      "search(node, #{String.trim(line)}\n);"
    end)
  end

  defp wrap_expressions(trimmed) do
    trimmed
    |> code_lines()
    |> Enum.map_join("\n", fn line ->
      "search(node, amenity: \"cafe\").filter(\n#{String.trim(line)}\n);"
    end)
  end

  defp wrap_multiline(trimmed) do
    trimmed
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      wrap_multiline_line(String.trim(line))
    end)
  end

  defp wrap_multiline_line(""), do: ""
  defp wrap_multiline_line("//" <> _ = line), do: line
  defp wrap_multiline_line("/*" <> _ = line), do: line

  defp wrap_multiline_line(line) do
    cond do
      String.ends_with?(line, "*/") -> line
      String.ends_with?(line, ";") -> line
      true -> line <> "\n;"
    end
  end

  defp multiline_without_semicolons?(s),
    do: not String.contains?(s, ";") and String.contains?(s, "\n")

  defp code_lines(s) do
    s
    |> String.split("\n")
    |> Enum.reject(fn line ->
      t = String.trim(line)
      t == "" or String.starts_with?(t, "//")
    end)
  end

  defp tag_filter_fragment?(s) do
    first = first_code_line(s)

    Regex.match?(~r/^~?"?[a-z_][a-z0-9_]*"?\s*:\s*[~!]*[*"i]/, first) and
      not String.starts_with?(first, "search") and
      not String.starts_with?(first, "$") and
      not String.starts_with?(first, "#")
  end

  defp comment_only?(s) do
    s
    |> String.split("\n")
    |> Enum.all?(&comment_or_plain_line?/1)
  end

  defp comment_or_plain_line?(line) do
    trimmed = String.trim(line)

    trimmed == "" or String.starts_with?(trimmed, "//") or
      String.starts_with?(trimmed, "/*") or String.ends_with?(trimmed, "*/") or
      (not String.contains?(trimmed, "(") and not String.contains?(trimmed, "=") and
         not String.contains?(trimmed, ":") and not String.contains?(trimmed, "."))
  end

  defp expression_fragment?(s) do
    first = first_code_line(s)

    String.starts_with?(first, "t[") or
      String.starts_with?(first, "number(") or
      String.starts_with?(first, "is_number(")
  end

  defp first_code_line(s) do
    s
    |> String.split("\n")
    |> hd()
    |> String.trim()
  end
end
