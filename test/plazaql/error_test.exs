defmodule PlazaQL.ErrorTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Error

  @multiline_source """
  [bbox:47.3,8.5,47.4,8.6];
  route = search(route: "tram");
  search(amenity: "cafe").within($r);
  out geom;\
  """

  describe "format/2" do
    test "formats error with all fields" do
      error = %Error{
        line: 3,
        col: 25,
        message: "`.within()` requires an Area or Polygon variable",
        hint: "use `.along($r, 200)` to search near the route geometry"
      }

      result = Error.format(error, @multiline_source)

      assert result =~ "error: `.within()` requires an Area or Polygon variable"
      assert result =~ "--> query:3:25"
      assert result =~ ~S[ 3 | search(amenity: "cafe").within($r);]
      assert result =~ "^"
      assert result =~ "= hint: use `.along($r, 200)` to search near the route geometry"
    end

    test "formats error without hint" do
      error = %Error{
        line: 2,
        col: 1,
        message: "unexpected token"
      }

      result = Error.format(error, @multiline_source)

      assert result =~ "error: unexpected token"
      assert result =~ "--> query:2:1"
      refute result =~ "= hint:"
    end

    test "formats warning severity" do
      error = %Error{
        line: 1,
        col: 1,
        message: "unused variable `$x`",
        severity: :warning
      }

      result = Error.format(error, @multiline_source)
      assert result =~ "warning: unused variable `$x`"
    end

    test "formats error at first line" do
      error = %Error{
        line: 1,
        col: 2,
        message: "invalid bbox"
      }

      result = Error.format(error, @multiline_source)

      assert result =~ "--> query:1:2"
      assert result =~ "1 | [bbox:47.3,8.5,47.4,8.6];"
    end

    test "formats error at last line" do
      error = %Error{
        line: 4,
        col: 1,
        message: "unexpected end of input"
      }

      result = Error.format(error, @multiline_source)

      assert result =~ "--> query:4:1"
      assert result =~ "4 | out geom;"
    end

    test "handles single-line source" do
      error = %Error{
        line: 1,
        col: 5,
        message: "bad token"
      }

      result = Error.format(error, "out geom;")

      assert result =~ "--> query:1:5"
      assert result =~ "1 | out geom;"
    end

    test "handles empty source gracefully" do
      error = %Error{
        line: 1,
        col: 1,
        message: "empty query"
      }

      result = Error.format(error, "")

      assert result =~ "error: empty query"
      assert result =~ "--> query:1:1"
    end

    test "truncates very long source lines" do
      long_line = String.duplicate("a", 200)

      error = %Error{
        line: 1,
        col: 150,
        message: "error in long line"
      }

      result = Error.format(error, long_line)

      assert result =~ "..."
      assert result =~ "^"
    end
  end

  describe "format_all/2" do
    test "formats multiple errors sorted by position" do
      errors = [
        %Error{line: 3, col: 10, message: "second error"},
        %Error{line: 1, col: 5, message: "first error"},
        %Error{line: 3, col: 1, message: "also line 3 but earlier col", severity: :warning}
      ]

      result = Error.format_all(errors, @multiline_source)

      parts = String.split(result, "\n\n")
      assert length(parts) == 3

      assert Enum.at(parts, 0) =~ "first error"
      assert Enum.at(parts, 1) =~ "also line 3 but earlier col"
      assert Enum.at(parts, 2) =~ "second error"
    end

    test "formats single error list" do
      errors = [%Error{line: 1, col: 1, message: "only one"}]
      result = Error.format_all(errors, @multiline_source)
      assert result =~ "only one"
    end
  end
end
