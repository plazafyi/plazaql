defmodule PlazaQLTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Error

  # ── Helpers ──────────────────────────────────────────────────────

  defp compile_errors(source) do
    case PlazaQL.compile(source) do
      {:ok, _} -> flunk("Expected errors but compile succeeded for: #{source}")
      {:error, errors} -> errors
    end
  end

  defp assert_error_struct(%Error{} = error) do
    assert is_integer(error.line), "line must be an integer, got: #{inspect(error.line)}"
    assert is_integer(error.col), "col must be an integer, got: #{inspect(error.col)}"
    assert is_binary(error.message), "message must be a string, got: #{inspect(error.message)}"
    assert error.message != "", "message must not be empty"
    assert error.severity in [:error, :warning], "severity must be :error or :warning"
    error
  end

  # ── Existing basic tests ────────────────────────────────────────

  describe "compile/1" do
    test "end-to-end from source string" do
      {:ok, result} = PlazaQL.compile(~s|$$ = search(node, amenity: "cafe").limit(5);|)
      plan = hd(result.plans)
      assert plan.element_types == [:node]
      assert plan.tag_filters == [{:eq, "amenity", "cafe"}]
      assert plan.limit == 5
    end

    test "returns error on invalid syntax" do
      assert {:error, [%PlazaQL.Error{}]} = PlazaQL.compile("invalid!!!")
    end

    test "compiles computation" do
      {:ok, result} = PlazaQL.compile(~s|$$ = route(point(38.9, -77.0), point(39.0, -76.5));|)
      plan = hd(result.plans)
      assert plan.kind == :computation
    end
  end

  # ── Parse errors propagate ─────────────────────────────────────

  describe "parse errors propagate through compile/1" do
    test "completely invalid input returns parse error with position" do
      [error] = compile_errors("invalid!!!")
      assert_error_struct(error)
      assert error.line == 1
      assert error.col == 1
      assert error.message =~ "unexpected input"
      assert error.severity == :error
    end

    test "typo in function name returns parse error" do
      [error] = compile_errors("serach(node);")
      assert_error_struct(error)
      assert error.line == 1
      assert error.col == 1
      assert error.message =~ "unexpected input"
      assert error.severity == :error
    end

    test "unclosed parenthesis returns parse error" do
      errors = compile_errors(~s|$$ = search(node, amenity: "cafe";|)
      assert errors != []
      error = hd(errors)
      assert_error_struct(error)
      assert error.severity == :error
    end

    test "unclosed string literal returns parse error" do
      errors = compile_errors(~s|$$ = search(node, amenity: "cafe);|)
      assert errors != []
      assert_error_struct(hd(errors))
    end

    test "missing semicolon returns parse error" do
      errors = compile_errors(~s|$$ = search(node, amenity: "cafe")|)
      assert errors != []
      assert_error_struct(hd(errors))
    end

    test "empty input is handled without crash" do
      # Empty input may succeed (empty program) or return an error — either is valid
      result = PlazaQL.compile("")
      assert match?({:ok, _}, result) or match?({:error, [%Error{} | _]}, result)
    end
  end

  # ── Type errors propagate ──────────────────────────────────────

  describe "type errors propagate through compile/1" do
    test "undefined variable has position and hint" do
      [error] = compile_errors(~s|$$ = search(node).within($missing);|)
      assert_error_struct(error)
      assert error.line == 1
      assert error.col >= 1
      assert error.message =~ "undefined variable `$missing`"
      assert is_binary(error.hint)
      assert error.hint =~ "define"
      assert error.severity == :error
    end

    test "forward reference produces error with position" do
      errors =
        compile_errors(~s|$$ = search(node).within($a); $a = boundary(name: "Berlin");|)

      error = Enum.find(errors, &(&1.message =~ "undefined variable `$a`"))
      assert_error_struct(error)
      assert error.line == 1
      assert error.col >= 1
    end

    test "duplicate variable produces error with position" do
      errors =
        compile_errors(~s|$a = boundary(name: "Berlin"); $a = boundary(name: "Munich"); $$ = $a;|)

      error = Enum.find(errors, &(&1.message =~ "duplicate variable"))
      assert_error_struct(error)
      assert error.message =~ "$a"
    end

    test "missing output statement produces error" do
      errors = compile_errors(~s|$a = boundary(name: "Berlin");|)
      error = Enum.find(errors, &(&1.message =~ "output"))
      assert_error_struct(error)
      assert error.severity == :error
    end

    test ".within() with wrong type has message and hint" do
      errors =
        compile_errors(
          ~s|$r = route(origin: point(0, 0), destination: point(1, 1)); $$ = search(node).within($r);|
        )

      error = Enum.find(errors, &(&1.message =~ "`.within()`"))
      assert_error_struct(error)
      assert error.message =~ "Route"
      assert is_binary(error.hint)
      assert error.hint =~ "around"
    end

    test ".offset() without .limit() has hint about adding limit" do
      [error] = compile_errors(~s|$$ = search(node).offset(10);|)
      assert_error_struct(error)
      assert error.message =~ "`.offset()` requires `.limit()`"
      assert is_binary(error.hint)
      assert error.hint =~ "limit"
    end

    test "chain ordering violation has hint about reordering" do
      errors = compile_errors(~s|$$ = search(node).limit(10).buffer(50);|)
      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert_error_struct(error)
      assert is_binary(error.hint)
      assert error.hint =~ "move"
    end

    test "method after terminal produces error" do
      errors = compile_errors(~s|$$ = search(node).count().limit(10);|)
      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert_error_struct(error)
      assert error.line == 1
    end
  end

  # ── Compiler errors propagate ──────────────────────────────────

  describe "compiler errors propagate through compile/1" do
    test "too many OSM IDs returns compiler error" do
      ids = Enum.map_join(1..10_001, ",", &to_string/1)
      errors = compile_errors("$$ = search(node, id: [#{ids}]);")
      error = hd(errors)
      assert_error_struct(error)
      assert error.message =~ "too many IDs"
    end
  end

  # ── Error struct completeness ──────────────────────────────────

  describe "error struct completeness" do
    test "parse errors have all required fields" do
      [error] = compile_errors("invalid!!!")
      assert_error_struct(error)
      assert error.line >= 1
      assert error.col >= 1
      # Parse errors may not have hints
      assert is_nil(error.hint) or is_binary(error.hint)
    end

    test "type errors have all required fields including hint" do
      errors =
        compile_errors(
          ~s|$r = route(origin: point(0, 0), destination: point(1, 1)); $$ = search(node).within($r);|
        )

      error = Enum.find(errors, &(&1.message =~ "`.within()`"))
      assert_error_struct(error)
      assert error.line >= 1
      assert error.col >= 1
      assert is_binary(error.hint)
    end

    test "chain ordering errors have all required fields including hint" do
      errors = compile_errors(~s|$$ = search(node).limit(10).buffer(50);|)
      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert_error_struct(error)
      assert error.line >= 1
      assert error.col >= 1
      assert is_binary(error.hint)
    end

    test "undefined variable errors have all required fields including hint" do
      [error] = compile_errors(~s|$$ = search(node).within($nope);|)
      assert_error_struct(error)
      assert error.line >= 1
      assert error.col >= 1
      assert is_binary(error.hint)
      assert error.hint =~ "define"
    end

    test "offset-without-limit errors have all required fields including hint" do
      [error] = compile_errors(~s|$$ = search(node).offset(10);|)
      assert_error_struct(error)
      assert error.line >= 1
      assert error.col >= 1
      assert is_binary(error.hint)
    end
  end

  # ── Error formatting integration ───────────────────────────────

  describe "Error.format/2 with real parse/compile errors" do
    test "formats a parse error with source snippet and caret" do
      source = "invalid!!!"
      [error] = compile_errors(source)
      formatted = Error.format(error, source)
      assert formatted =~ "error:"
      assert formatted =~ "unexpected input"
      assert formatted =~ "query:1:1"
      assert formatted =~ "^"
      assert formatted =~ "invalid!!!"
    end

    test "formats a type error with hint line" do
      source = ~s|$$ = search(node).within($missing);|
      [error] = compile_errors(source)
      formatted = Error.format(error, source)
      assert formatted =~ "error:"
      assert formatted =~ "undefined variable"
      assert formatted =~ "^"
      assert formatted =~ "= hint:"
      assert formatted =~ "define"
    end

    test "formats a chain ordering error with source context" do
      source = ~s|$$ = search(node).limit(10).buffer(50);|
      errors = compile_errors(source)
      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      formatted = Error.format(error, source)
      assert formatted =~ "error:"
      assert formatted =~ "cannot follow"
      assert formatted =~ source
      assert formatted =~ "^"
      assert formatted =~ "= hint:"
    end

    test "format_all sorts multiple errors and separates with blank lines" do
      source = ~s|$$ = search(node).limit(10).buffer(50).within($missing);|
      {:error, errors} = PlazaQL.compile(source)
      assert length(errors) >= 2
      formatted = Error.format_all(errors, source)

      # Each error separated by blank line
      sections = String.split(formatted, "\n\n")
      assert length(sections) >= 2

      # All sections start with "error:"
      for section <- sections do
        assert String.starts_with?(String.trim(section), "error:")
      end
    end

    test "format_all preserves line/col sort order" do
      source = ~s|$$ = search(node).limit(10).buffer(50).within($missing);|
      {:error, errors} = PlazaQL.compile(source)
      formatted = Error.format_all(errors, source)

      # Extract column numbers from "query:LINE:COL" markers
      cols =
        Regex.scan(~r/query:(\d+):(\d+)/, formatted)
        |> Enum.map(fn [_, line, col] -> {String.to_integer(line), String.to_integer(col)} end)

      assert cols == Enum.sort(cols)
    end
  end

  # ── Multiple error accumulation ────────────────────────────────

  describe "multiple error accumulation" do
    test "chain ordering + undefined variable returns all errors" do
      errors =
        compile_errors(~s|$$ = search(node).limit(10).buffer(50).within($missing);|)

      assert length(errors) >= 3

      assert Enum.any?(errors, &(&1.message =~ "cannot follow"))
      assert Enum.any?(errors, &(&1.message =~ "undefined variable"))
    end

    test "errors are sorted by line then column" do
      errors =
        compile_errors(~s|$$ = search(node).limit(10).buffer(50).within($missing);|)

      positions = Enum.map(errors, &{&1.line, &1.col})
      assert positions == Enum.sort(positions)
    end

    test "multiple output modes report error" do
      errors = compile_errors(~s|$$ = search(node).count().ids();|)
      assert Enum.any?(errors, &(&1.message =~ "multiple output modes"))
    end

    test "duplicate variable and missing output accumulate" do
      errors =
        compile_errors(~s|$a = boundary(name: "Berlin"); $a = boundary(name: "Munich");|)

      assert Enum.any?(errors, &(&1.message =~ "duplicate variable"))
      assert Enum.any?(errors, &(&1.message =~ "output"))
    end

    test "multiline query accumulates errors with correct line numbers" do
      source = """
      $a = boundary(name: "Berlin");
      $$ = search(node).within($a).limit(10).buffer(50);\
      """

      errors = compile_errors(source)
      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert_error_struct(error)
      assert error.line == 2
    end
  end

  # ── Realistic error scenarios ──────────────────────────────────

  describe "realistic user mistakes" do
    test "typo in function name: serach(node)" do
      errors = compile_errors("serach(node);")
      assert errors != []
      error = hd(errors)
      assert_error_struct(error)
      assert error.severity == :error
      # Parser cannot recognize the function, so it is a parse error
      assert error.message =~ "unexpected input"
    end

    test "using wrong variable syntax: $a = search(node); search(node).within(a);" do
      # 'a' without $ is not a variable reference — should fail
      errors = compile_errors(~s|$a = search(node); search(node).within(a);|)
      assert errors != []
      assert_error_struct(hd(errors))
    end

    test "chaining .within() with a route instead of area" do
      source =
        ~s|$r = route(origin: point(38.9, -77.0), destination: point(40.7, -74.0)); $$ = search(node, amenity: "cafe").within($r);|

      errors = compile_errors(source)
      error = Enum.find(errors, &(&1.message =~ "`.within()`"))
      assert_error_struct(error)
      assert error.message =~ "Route"
      assert is_binary(error.hint)
      assert error.hint =~ "around"
    end

    test "chaining methods in wrong order: transform after ordering" do
      errors = compile_errors(~s|$$ = search(node, amenity: "cafe").limit(10).buffer(50);|)
      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert_error_struct(error)
      assert error.message =~ "`.buffer()`"
      assert error.message =~ "`.limit()`"
      assert is_binary(error.hint)
    end

    test "narrowing an already-narrowed element: .first().first()" do
      errors = compile_errors(~s|$$ = search(node).first().first();|)
      error = Enum.find(errors, &(&1.message =~ "already a single element"))
      assert_error_struct(error)
    end

    test ".index(0) rejected — must be positive integer" do
      errors = compile_errors(~s|$$ = search(node).index(0);|)
      error = Enum.find(errors, &(&1.message =~ "positive integer"))
      assert_error_struct(error)
    end

    test "mixing simple output and named output" do
      errors = compile_errors(~s|$$ = search(amenity: "cafe"); $$.foo = search(amenity: "bar");|)
      error = Enum.find(errors, &(&1.message =~ "cannot mix"))
      assert_error_struct(error)
    end

    test "duplicate named output" do
      errors =
        compile_errors(~s|$$.foo = search(amenity: "cafe"); $$.foo = search(amenity: "bar");|)

      error = Enum.find(errors, &(&1.message =~ "duplicate output variable"))
      assert_error_struct(error)
      assert error.message =~ "$$.foo"
    end

    test "multiple simple outputs" do
      errors = compile_errors(~s|$$ = search(amenity: "cafe"); $$ = search(amenity: "bar");|)
      error = Enum.find(errors, &(&1.message =~ "only one simple output"))
      assert_error_struct(error)
    end

    test ".sort(by: :distance) without .around() context" do
      errors =
        compile_errors(
          ~s|$$ = search(node, amenity: "cafe").bbox(40.7, -74.0, 40.8, -73.9).sort(by: :distance);|
        )

      error = Enum.find(errors, &(&1.message =~ "`.sort(by: :distance)` requires"))
      assert_error_struct(error)
    end

    test "group_by followed by non-aggregation terminal" do
      errors = compile_errors(~s|$$ = search(node).group_by(t["amenity"]).ids();|)
      error = Enum.find(errors, &(&1.message =~ "cannot be applied to GroupedSet"))
      assert_error_struct(error)
    end

    test "method after aggregation terminal" do
      errors =
        compile_errors(~s|$$ = search(node).sum(number(t["capacity"])).limit(10);|)

      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert_error_struct(error)
    end

    test "undefined output variable reference" do
      errors = compile_errors(~s|$$.stops = search(node).within($$.missing);|)
      error = Enum.find(errors, &(&1.message =~ "undefined output variable"))
      assert_error_struct(error)
      assert error.message =~ "$$.missing"
    end

    test "filter_expr after terminal is rejected" do
      errors = compile_errors(~s|$$ = search(node).count().filter(id() > 1);|)
      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert_error_struct(error)
    end
  end

  # ── parse/1 and check/1 entry points ───────────────────────────

  describe "parse/1 entry point" do
    test "returns parse error for invalid syntax" do
      {:error, [error]} = PlazaQL.parse("invalid!!!")
      assert_error_struct(error)
      assert error.message =~ "unexpected input"
    end

    test "returns ok for valid syntax" do
      assert {:ok, _ast} = PlazaQL.parse(~s|$$ = search(node, amenity: "cafe");|)
    end
  end

  describe "check/1 entry point" do
    test "returns type error for undefined variable" do
      {:error, errors} = PlazaQL.check(~s|$$ = search(node).within($nope);|)
      error = Enum.find(errors, &(&1.message =~ "undefined variable"))
      assert_error_struct(error)
    end

    test "returns parse error for invalid syntax (does not reach type checker)" do
      {:error, [error]} = PlazaQL.check("invalid!!!")
      assert_error_struct(error)
      assert error.message =~ "unexpected input"
    end

    test "returns ok for valid query" do
      assert {:ok, _typed} = PlazaQL.check(~s|$$ = search(node, amenity: "cafe");|)
    end
  end

  # ── query/1 entry point ────────────────────────────────────────

  describe "query/1 entry point" do
    test "parse errors propagate through query/1" do
      {:error, [error]} = PlazaQL.query("invalid!!!")
      assert_error_struct(error)
      assert error.message =~ "unexpected input"
    end

    test "type errors propagate through query/1" do
      {:error, errors} = PlazaQL.query(~s|$$ = search(node).within($missing);|)
      error = Enum.find(errors, &(&1.message =~ "undefined variable"))
      assert_error_struct(error)
    end
  end
end
