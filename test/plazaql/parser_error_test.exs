defmodule PlazaQL.ParserErrorTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Error
  alias PlazaQL.Parser

  # Helper: parse and assert error tuple with at least one Error struct
  defp assert_parse_error(source) do
    assert {:error, errors} = Parser.parse(source)
    assert is_list(errors)
    assert errors != []

    for error <- errors do
      assert %Error{} = error
      assert is_integer(error.line) and error.line >= 1
      assert is_integer(error.col) and error.col >= 1
      assert is_binary(error.message) and error.message != ""
      assert error.severity == :error
    end

    errors
  end

  # ── Syntax errors ──────────────────────────────────────────────

  describe "missing semicolons" do
    test "single statement without semicolon" do
      [error] = assert_parse_error(~s|search(node, amenity: "cafe")|)
      assert error.line == 1
      # col points to end of input where semicolon was expected
      assert error.col == 30
    end

    test "second statement missing semicolon triggers error" do
      [error] =
        assert_parse_error(~s|search(node, amenity: "cafe");\nsearch(way, natural: "water")|)

      # Error on the second statement's end
      assert error.line in [1, 2]
    end
  end

  describe "unclosed parentheses" do
    test "unclosed paren in search call" do
      [error] = assert_parse_error("search(")
      assert error.line == 1
      assert error.col == 1
      assert error.message =~ "unexpected input"
    end

    test "unclosed paren with arguments" do
      [error] = assert_parse_error(~s|search(node, amenity: "cafe"|)
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "unclosed paren in method call" do
      [error] = assert_parse_error(~s|search(node, amenity: "cafe").limit(;|)
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "unclosed paren in nested function" do
      [error] = assert_parse_error("route(origin: point(38.9, -77.0;")
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end
  end

  describe "unclosed strings" do
    test "unclosed double-quoted string" do
      [error] = assert_parse_error(~s|search(node, amenity: "cafe);|)
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "unclosed string at end of input" do
      [error] = assert_parse_error(~s|$$ = search(amenity: "cafe|)
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end
  end

  describe "unclosed brackets" do
    test "unclosed square bracket in tag access" do
      [error] = assert_parse_error(~s|search(node, [amenity: "cafe");|)
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end
  end

  # ── Invalid tokens ────────────────────────────────────────────

  describe "invalid tokens" do
    test "random garbage characters" do
      [error] = assert_parse_error("!!!")
      assert error.line == 1
      assert error.col == 1
      assert error.message =~ "unexpected input"
      assert error.message =~ "!!!"
    end

    test "bare semicolon with no statement" do
      [error] = assert_parse_error(";")
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "operator in wrong position — leading plus" do
      [error] = assert_parse_error("+ search(node);")
      assert error.line == 1
      assert error.col == 1
      assert error.message =~ "unexpected input"
    end

    test "operator in wrong position — leading minus" do
      [error] = assert_parse_error("- search(node);")
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "double dots in method chain" do
      [error] = assert_parse_error(~s|search(node)..limit(10);|)
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "hash symbol is not valid" do
      [error] = assert_parse_error("# this is not a comment\n;")
      assert error.line >= 1
      assert error.message =~ "unexpected input"
    end
  end

  # ── Incomplete statements ─────────────────────────────────────

  describe "incomplete statements" do
    test "search( with no closing paren or arguments" do
      [error] = assert_parse_error("search(")
      assert error.line == 1
      assert error.message =~ "unexpected input"
      assert error.message =~ "search("
    end

    test "$$ = with no value" do
      [error] = assert_parse_error("$$ =")
      assert error.line == 1
      assert error.message =~ "unexpected input"
      assert error.message =~ "$$"
    end

    test "$$ = with no value and semicolon" do
      [error] = assert_parse_error("$$ = ;")
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "variable assignment with no value" do
      [error] = assert_parse_error("$x = ;")
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "method chain with no method name" do
      [error] = assert_parse_error(~s|search(node, amenity: "cafe").;|)
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "point with missing closing paren" do
      [error] = assert_parse_error("$p = point(38.9, -77.0;")
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "route with no arguments" do
      # route() with no args and semicolon may or may not error depending on grammar
      # but route( without closing should definitely error
      [error] = assert_parse_error("route(;")
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end
  end

  # ── Error position accuracy ───────────────────────────────────

  describe "error position accuracy" do
    test "error on first line, first column for leading garbage" do
      [error] = assert_parse_error("@@@")
      assert error.line == 1
      assert error.col == 1
    end

    test "error column points past valid content when semicolon missing" do
      [error] = assert_parse_error(~s|search(node, amenity: "cafe")|)
      # Column should be at or near position 30 (end of the valid text)
      assert error.col >= 28
    end

    test "error on second line for multiline input" do
      source = ~s|search(node, amenity: "cafe");\nsearch(|
      [error] = assert_parse_error(source)
      assert error.line == 2
      assert error.col == 1
    end

    test "error on third line in multiline input" do
      source = ~s|search(node, amenity: "cafe");\nsearch(way, natural: "water");\n!!!|
      [error] = assert_parse_error(source)
      assert error.line == 3
      assert error.col == 1
    end

    test "error column is accurate mid-line" do
      # The bracket starts at column 14
      [error] = assert_parse_error(~s|search(node, [amenity: "cafe");|)
      assert error.line == 1
      assert error.col >= 14
    end
  end

  # ── Error message quality ─────────────────────────────────────

  describe "error message quality" do
    test "message includes source context snippet" do
      [error] = assert_parse_error("search(")
      # Message should show what was found near the error, not just "syntax error"
      assert error.message =~ "search("
    end

    test "message for garbage includes the offending text" do
      [error] = assert_parse_error("!!!")
      assert error.message =~ "!!!"
    end

    test "message mentions unexpected input" do
      [error] = assert_parse_error("+ foo;")
      assert error.message =~ "unexpected input"
    end

    test "message is not a bare 'syntax error' without context" do
      [error] = assert_parse_error(~s|search(node, amenity: "cafe").limit(;|)
      # Should have more context than just "syntax error"
      assert String.length(error.message) > 15
      assert error.message =~ "unexpected input near"
    end

    test "message for unclosed string includes the string content" do
      [error] = assert_parse_error(~s|search(node, amenity: "cafe)|)
      assert error.message =~ "cafe"
    end
  end

  # ── Error struct fields ───────────────────────────────────────

  describe "error struct completeness" do
    test "error has all required fields" do
      [error] = assert_parse_error("!!!")
      assert Map.has_key?(error, :line)
      assert Map.has_key?(error, :col)
      assert Map.has_key?(error, :message)
      assert Map.has_key?(error, :hint)
      assert Map.has_key?(error, :severity)
    end

    test "severity defaults to :error" do
      [error] = assert_parse_error("!!!")
      assert error.severity == :error
    end

    test "Error.format/2 produces formatted diagnostic" do
      source = "search("
      [error] = assert_parse_error(source)
      formatted = Error.format(error, source)
      assert formatted =~ "error:"
      assert formatted =~ "unexpected input"
      assert formatted =~ "query:1:"
      assert formatted =~ "^"
    end

    test "Error.format_all/2 formats multiple errors" do
      # Build errors manually to test format_all since parser takes at most 1
      errors = [
        %Error{line: 2, col: 5, message: "second error"},
        %Error{line: 1, col: 1, message: "first error"}
      ]

      source = "line one\nline two"
      formatted = Error.format_all(errors, source)
      # format_all sorts by position, so "first error" should come before "second error"
      first_pos = :binary.match(formatted, "first error") |> elem(0)
      second_pos = :binary.match(formatted, "second error") |> elem(0)
      assert first_pos < second_pos
    end
  end

  # ── Edge cases ────────────────────────────────────────────────

  describe "edge cases" do
    test "empty string parses successfully (no error)" do
      assert {:ok, []} = Parser.parse("")
    end

    test "whitespace-only parses successfully (no error)" do
      assert {:ok, []} = Parser.parse("   \n  \n  ")
    end

    test "valid comment-only input parses successfully" do
      assert {:ok, []} = Parser.parse("// this is a comment\n")
    end

    test "very long garbage input still produces an error" do
      garbage = String.duplicate("x", 500)
      [error] = assert_parse_error(garbage)
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end

    test "null bytes produce an error" do
      [error] = assert_parse_error("\0")
      assert error.line >= 1
      # Null bytes cause XML parse failures since they're illegal characters
      assert error.message =~ "unexpected input" or error.message =~ "XML parse error"
    end

    test "only keywords without structure produce an error" do
      [error] = assert_parse_error("node way relation")
      assert error.line == 1
      assert error.message =~ "unexpected input"
    end
  end
end
