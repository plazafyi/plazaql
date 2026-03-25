defmodule PlazaQL.Error do
  @moduledoc """
  Structured error type used by all PlazaQL modules (parser, type checker, compiler).

  Produces rich formatted output with source snippets, caret pointers, and hints,
  following Rust/Elm-style diagnostic formatting.
  """

  @type severity :: :error | :warning

  @type t :: %__MODULE__{
          line: pos_integer(),
          col: pos_integer(),
          message: String.t(),
          hint: String.t() | nil,
          severity: severity()
        }

  @enforce_keys [:line, :col, :message]
  defstruct [:line, :col, :message, :hint, severity: :error]

  @max_line_length 120

  @doc """
  Format an error with source context snippet.

  Produces output like:

      error: `.within()` requires an Area or Polygon variable
        --> query:3:25
         |
       3 | search(amenity: "cafe").within($r);
         |                         ^^^^^^
         |
         = hint: use `.along($r, 200)` to search near the route geometry

  """
  @spec format(t(), String.t()) :: String.t()
  def format(%__MODULE__{} = error, source_text) do
    source_line =
      source_text
      |> String.split("\n")
      |> Enum.at(error.line - 1, "")

    {display_line, display_col} = maybe_truncate(source_line, error.col)

    line_num = Integer.to_string(error.line)
    gutter = String.duplicate(" ", String.length(line_num) + 2)

    hint_line = if error.hint, do: ["#{gutter}= hint: #{error.hint}"], else: []

    [
      "#{error.severity}: #{error.message}",
      "#{gutter}--> query:#{error.line}:#{error.col}",
      "#{gutter}|",
      " #{line_num} | #{display_line}",
      "#{gutter}| #{String.duplicate(" ", max(display_col - 1, 0))}^",
      "#{gutter}|"
      | hint_line
    ]
    |> Enum.join("\n")
  end

  @doc """
  Format a list of errors, sorted by line then column.

  Each error is separated by a blank line.
  """
  @spec format_all([t()], String.t()) :: String.t()
  def format_all(errors, source_text) do
    errors
    |> Enum.sort_by(&{&1.line, &1.col})
    |> Enum.map_join("\n\n", &format(&1, source_text))
  end

  defp maybe_truncate(line, col) when byte_size(line) <= @max_line_length, do: {line, col}

  defp maybe_truncate(line, col) do
    # Show a window around the error column
    half = div(@max_line_length, 2)

    cond do
      col <= half ->
        truncated = String.slice(line, 0, @max_line_length) <> "..."
        {truncated, col}

      col >= (len = String.length(line)) - half ->
        start = len - @max_line_length
        truncated = "..." <> String.slice(line, start, @max_line_length)
        {truncated, col - start + 3}

      true ->
        start = col - half
        truncated = "..." <> String.slice(line, start, @max_line_length) <> "..."
        {truncated, col - start + 3}
    end
  end
end
