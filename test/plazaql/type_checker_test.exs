defmodule PlazaQL.TypeCheckerTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Parser
  alias PlazaQL.TypeChecker

  defp check!(source) do
    {:ok, ast} = Parser.parse(source)

    case TypeChecker.check(ast) do
      {:ok, typed} -> typed
      {:error, errors} -> flunk("Type check failed:\n#{inspect(errors, pretty: true)}")
    end
  end

  defp check_errors(source) do
    {:ok, ast} = Parser.parse(source)

    case TypeChecker.check(ast) do
      {:ok, _} -> flunk("Expected type errors but check passed for: #{source}")
      {:error, errors} -> errors
    end
  end

  defp output_type(source) do
    typed = check!(source)
    {:output, _, _expr, pos} = Enum.find(typed, &match?({:output, _, _, _}, &1))
    pos.type
  end

  defp output_expr_type(source) do
    typed = check!(source)
    {:output, _, expr, _} = Enum.find(typed, &match?({:output, _, _, _}, &1))
    TypeChecker.expr_type(expr)
  end

  defp var_type(source, var_name) do
    typed = check!(source)

    {:var_assign, ^var_name, _expr, pos} =
      Enum.find(typed, &match?({:var_assign, ^var_name, _, _}, &1))

    pos.type
  end

  # ── Type inference: geometry constructors ─────────────────────────

  describe "type inference — geometry constructors" do
    test "point() infers :point" do
      assert var_type(~s|$p = point(38.9, -77.0); $$ = $p;|, "$p") == :point
    end

    test "linestring() infers :linestring" do
      assert var_type(
               ~s|$l = linestring(point(0, 0), point(1, 1)); $$ = $l;|,
               "$l"
             ) == :linestring
    end

    test "polygon() infers :polygon" do
      assert var_type(
               ~s|$g = polygon(point(0, 0), point(1, 0), point(0, 1)); $$ = $g;|,
               "$g"
             ) == :polygon
    end

    test "bbox() infers :polygon" do
      assert var_type(~s|$b = bbox(40.7, -74.0, 40.8, -73.9); $$ = $b;|, "$b") == :polygon
    end
  end

  # ── Type inference: search variants ───────────────────────────────

  describe "type inference — search" do
    test "search(node, ...) infers :point_set" do
      assert output_type(~s|$$ = search(node, amenity: "cafe");|) == :point_set
    end

    test "search(way, ...) infers :geo_set" do
      assert output_type(~s|$$ = search(way, highway: "primary");|) == :geo_set
    end

    test "search(relation, ...) infers :geo_set" do
      assert output_type(~s|$$ = search(relation, type: "route");|) == :geo_set
    end

    test "search(...) with no type infers :geo_set" do
      assert output_type(~s|$$ = search(amenity: "cafe");|) == :geo_set
    end
  end

  # ── Type inference: computations ──────────────────────────────────

  describe "type inference — computations" do
    test "boundary() infers :boundary" do
      assert var_type(
               ~s|$a = boundary(name: "Berlin", admin_level: "4"); $$ = $a;|,
               "$a"
             ) == :boundary
    end

    test "route() infers :route" do
      assert var_type(
               ~s|$r = route(origin: point(38.9, -77.0), destination: point(40.7, -74.0)); $$ = $r;|,
               "$r"
             ) == :route
    end

    test "isochrone() infers :isochrone" do
      assert var_type(
               ~s|$i = isochrone(center: point(38.9, -77.0), time: 600); $$ = $i;|,
               "$i"
             ) == :isochrone
    end

    test "geocode() infers :point_set" do
      assert var_type(~s|$g = geocode(text: "Berlin"); $$ = $g;|, "$g") == :point_set
    end

    test "matrix() infers :matrix" do
      assert var_type(
               ~s|$m = matrix(origins: [point(0, 0)], destinations: [point(1, 1)]); $$ = $m;|,
               "$m"
             ) == :matrix
    end

    test "elevation() infers :elevation" do
      assert var_type(~s|$e = elevation(point: point(38.9, -77.0)); $$ = $e;|, "$e") ==
               :elevation
    end
  end

  # ── Type inference: transforms ────────────────────────────────────

  describe "type inference — transforms" do
    test ".buffer() produces :polygon_set" do
      assert output_type(~s|$$ = search(node, amenity: "cafe").buffer(50);|) == :polygon_set
    end

    test ".centroid() produces :point_set" do
      assert output_type(~s|$$ = search(way, building: "yes").centroid();|) == :point_set
    end

    test ".count() produces :scalar" do
      assert output_type(~s|$$ = search(node, amenity: "cafe").count();|) == :scalar
    end
  end

  # ── Variable tracking ────────────────────────────────────────────

  describe "variable tracking" do
    test "defined variable has correct type" do
      assert var_type(
               ~s|$a = boundary(name: "Berlin"); $$ = search(node, amenity: "cafe").within($a);|,
               "$a"
             ) == :boundary
    end

    test "variable type propagates through references" do
      source = ~s|$a = boundary(name: "Berlin"); $$ = $a;|
      assert output_type(source) == :boundary
    end

    test "undefined variable produces error" do
      errors = check_errors(~s|$$ = search(node, amenity: "cafe").within($missing);|)
      error = Enum.find(errors, &(&1.message =~ "undefined variable `$missing`"))
      assert error.line == 1
      assert error.col == 43
      assert error.severity == :error
      assert error.hint =~ "define it first"
    end

    test "forward reference produces error" do
      errors =
        check_errors(~s|$$ = search(node).within($a); $a = boundary(name: "Berlin");|)

      error = Enum.find(errors, &(&1.message =~ "undefined variable `$a`"))
      assert error.line == 1
      assert error.col == 26
      assert error.severity == :error
      assert error.hint =~ "define it first"
    end

    test "duplicate variable produces error" do
      errors =
        check_errors(~s|$a = boundary(name: "Berlin"); $a = boundary(name: "Munich"); $$ = $a;|)

      error = Enum.find(errors, &(&1.message =~ "duplicate variable `$a`"))
      assert error.line == 1
      assert error.col == 32
      assert error.severity == :error
      assert error.hint =~ "choose a different name"
    end
  end

  # ── Chain ordering ────────────────────────────────────────────────

  describe "chain ordering" do
    test "valid ordering passes: spatial -> transform -> ordering" do
      check!(
        ~s|$a = boundary(name: "Berlin"); $$ = search(node, amenity: "cafe").within($a).buffer(50).limit(10);|
      )
    end

    test "transform after ordering produces error" do
      errors =
        check_errors(~s|$$ = search(node, amenity: "cafe").limit(10).buffer(50);|)

      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert error.line == 1
      assert error.col == 46
      assert error.severity == :error
      assert error.message =~ ".buffer()"
      assert error.message =~ ".limit()"
      assert error.hint =~ "move `.buffer()` before `.limit()`"
    end

    test "multiple methods in same phase allowed" do
      check!(
        ~s|$a = boundary(name: "Berlin"); $$ = search(node, amenity: "cafe").within($a).around(500, point(38.9, -77.0));|
      )
    end

    test "full valid chain passes" do
      check!(
        ~s|$a = boundary(name: "Berlin"); $$ = search(node, amenity: "cafe").within($a).filter(cuisine: "italian").buffer(50).precision(6).limit(10);|
      )
    end

    test "output mode after ordering is valid" do
      check!(~s|$$ = search(node, amenity: "cafe").limit(10).count();|)
    end

    test "spatial after transform is valid (relaxed ordering)" do
      check!(~s|$a = boundary(name: "Berlin"); $$ = search(node).buffer(50).within($a);|)
    end

    test "filter after transform is valid (relaxed ordering)" do
      check!(~s|$$ = search(node, amenity: "cafe").buffer(50).filter(cuisine: "italian");|)
    end

    test "enrichment before transform is valid (relaxed ordering)" do
      check!(
        ~s|$a = boundary(name: "Berlin"); $$ = search(node, amenity: "cafe").within($a).elevation().buffer(50);|
      )
    end

    test "output shape before transform is valid (relaxed ordering)" do
      check!(
        ~s|$a = boundary(name: "Berlin"); $$ = search(node, amenity: "cafe").within($a).precision(6).buffer(50);|
      )
    end

    test "spatial after ordering still errors" do
      errors =
        check_errors(~s|$a = boundary(name: "Berlin"); $$ = search(node).limit(10).within($a);|)

      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert error.line == 1
      assert error.col == 60
      assert error.severity == :error
      assert error.message =~ ".within()"
      assert error.message =~ ".limit()"
      assert error.hint =~ "move `.within()` before `.limit()`"
    end

    test "anything after output mode still errors" do
      errors =
        check_errors(~s|$$ = search(node, amenity: "cafe").count().limit(10);|)

      error = Enum.find(errors, &(&1.message =~ "cannot follow"))
      assert error.line == 1
      assert error.col == 44
      assert error.severity == :error
      assert error.message =~ ".limit()"
      assert error.message =~ ".count()"
      assert error.hint =~ "move `.limit()` before the output mode"
    end

    test "centroid then simplify is valid (relaxed type restriction)" do
      check!(
        ~s|$a = boundary(name: "Berlin"); $$ = search(way, building: "yes").within($a).centroid().simplify(10);|
      )
    end
  end

  # ── Method-type compatibility ─────────────────────────────────────

  describe "method-type compatibility" do
    test ".within() with area passes" do
      check!(~s|$a = boundary(name: "Berlin"); $$ = search(node, amenity: "cafe").within($a);|)
    end

    test ".within() with route produces error" do
      errors =
        check_errors(
          ~s|$r = route(origin: point(0, 0), destination: point(1, 1)); $$ = search(node, amenity: "cafe").within($r);|
        )

      error = Enum.find(errors, &(&1.message =~ "`.within()` requires"))
      assert error.line == 1
      assert error.col == 95
      assert error.severity == :error
      assert error.message =~ "Route"
      assert error.hint =~ "around"
    end

    test ".simplify() on PointSet is valid" do
      check!(~s|$$ = search(node, amenity: "cafe").simplify(10);|)
    end

    test ".around() with route passes (route is geometric)" do
      check!(
        ~s|$r = route(origin: point(0, 0), destination: point(1, 1)); $$ = search(node, amenity: "cafe").around(500, $r);|
      )
    end

    test ".within() with polygon passes" do
      check!(~s|$g = polygon(point(0, 0), point(1, 0), point(0, 1)); $$ = search(node).within($g);|)
    end

    test ".within() with isochrone passes" do
      check!(~s|$i = isochrone(center: point(0, 0), time: 600); $$ = search(node).within($i);|)
    end
  end

  # ── Contextual requirements ───────────────────────────────────────

  describe "contextual requirements" do
    test ".sort(by: :distance) without .around() produces error" do
      errors =
        check_errors(
          ~s|$$ = search(node, amenity: "cafe").bbox(40.7, -74.0, 40.8, -73.9).sort(by: :distance);|
        )

      error = Enum.find(errors, &(&1.message =~ "`.sort(by: :distance)` requires"))
      assert error.line == 1
      assert error.col == 67
      assert error.severity == :error
      assert error.hint =~ ".around("
    end

    test ".sort(by: :distance) with .around() passes" do
      check!(
        ~s|$$ = search(node, amenity: "cafe").around(500, point(38.9, -77.0)).sort(by: :distance);|
      )
    end

    test ".sort(:qt) without .around() passes" do
      check!(~s|$$ = search(node, amenity: "cafe").sort(by: :qt);|)
    end

    test ".offset() without .limit() produces error" do
      errors = check_errors(~s|$$ = search(node, amenity: "cafe").offset(10);|)

      error = Enum.find(errors, &(&1.message =~ "`.offset()` requires `.limit()`"))
      assert error.line == 1
      assert error.col == 36
      assert error.severity == :error
      assert error.hint =~ "limit"
    end

    test ".offset() with .limit() passes" do
      check!(~s|$$ = search(node, amenity: "cafe").limit(20).offset(10);|)
    end
  end

  # ── Output mode validation ────────────────────────────────────────

  describe "output mode" do
    test "two output modes produce error" do
      errors = check_errors(~s|$$ = search(node, amenity: "cafe").count().ids();|)

      error = Enum.find(errors, &(&1.message =~ "multiple output modes"))
      assert error.line == 1
      assert error.col == 44
      assert error.severity == :error
      assert error.hint =~ "only one output mode"
    end

    test "single output mode passes" do
      check!(~s|$$ = search(node, amenity: "cafe").ids();|)
    end

    test "missing output statement produces error" do
      errors = check_errors(~s|$a = boundary(name: "Berlin");|)

      error = Enum.find(errors, &(&1.message =~ "at least one output statement"))
      assert error.line == 1
      assert error.col == 1
      assert error.severity == :error
      assert error.hint =~ "add an expression"
    end
  end

  # ── Output statement validation ──────────────────────────────────

  describe "output statement validation" do
    test "single simple output is valid" do
      check!(~s|$$ = search(node, amenity: "cafe");|)
    end

    test "multiple named outputs are valid" do
      check!(~s|$$.foo = search(amenity: "cafe"); $$.bar = search(amenity: "bar");|)
    end

    test "multiple simple outputs produce error" do
      errors =
        check_errors(~s|$$ = search(amenity: "cafe"); $$ = search(amenity: "bar");|)

      error = Enum.find(errors, &(&1.message =~ "only one simple output"))
      assert error.line == 1
      assert error.col == 31
      assert error.severity == :error
      assert error.hint =~ "named outputs"
    end

    test "mixing simple and named output produces error" do
      errors =
        check_errors(~s|$$ = search(amenity: "cafe"); $$.foo = search(amenity: "bar");|)

      error = Enum.find(errors, &(&1.message =~ "cannot mix simple output"))
      assert error.line == 1
      assert error.col == 31
      assert error.severity == :error
      assert error.hint =~ "named outputs"
    end

    test "mixing named and simple output produces error" do
      errors =
        check_errors(~s|$$.foo = search(amenity: "cafe"); $$ = search(amenity: "bar");|)

      error = Enum.find(errors, &(&1.message =~ "cannot mix simple output"))
      assert error.line == 1
      assert error.col == 35
      assert error.severity == :error
      assert error.hint =~ "named outputs"
    end

    test "duplicate named output produces error" do
      errors =
        check_errors(~s|$$.foo = search(amenity: "cafe"); $$.foo = search(amenity: "bar");|)

      error = Enum.find(errors, &(&1.message =~ "duplicate output variable `$$.foo`"))
      assert error.line == 1
      assert error.col == 35
      assert error.severity == :error
      assert error.hint =~ "choose a different name"
    end
  end

  # ── Output variable references ─────────────────────────────────────

  describe "output variable references" do
    test "defined output variable has correct type" do
      typed =
        check!(~s|$$.area = boundary(name: "Berlin"); $$.cafes = search(node).within($$.area);|)

      {:output, "area", _, pos} = Enum.find(typed, &match?({:output, "area", _, _}, &1))
      assert pos.type == :boundary
    end

    test "output variable type propagates through references" do
      typed = check!(~s|$$.a = search(node, amenity: "cafe"); $$.b = $$.a;|)
      {:output, "b", _, pos} = Enum.find(typed, &match?({:output, "b", _, _}, &1))
      assert pos.type == :point_set
    end

    test "undefined output variable produces error" do
      errors = check_errors(~s|$$.stops = search(node).within($$.missing);|)

      error = Enum.find(errors, &(&1.message =~ "undefined output variable `$$.missing`"))
      assert error.line == 1
      assert error.col == 32
      assert error.severity == :error
      assert error.hint =~ "define it first"
      assert error.hint =~ "$$.missing"
    end

    test "forward reference to output variable produces error" do
      errors =
        check_errors(
          ~s|$$.stops = search(node).within($$.area); $$.area = boundary(name: "Berlin");|
        )

      error = Enum.find(errors, &(&1.message =~ "undefined output variable `$$.area`"))
      assert error.line == 1
      assert error.col == 32
      assert error.severity == :error
      assert error.hint =~ "define it first"
      assert error.hint =~ "$$.area"
    end

    test "output variable usable in around method" do
      check!(
        ~s|$$.route = route(origin: point(38.9, -77.0), destination: point(40.7, -74.0)); $$.stops = search(node, amenity: "cafe").around(200, $$.route);|
      )
    end
  end

  # ── Bare expression statements ───────────────────────────────────

  describe "bare expression statements" do
    test "bare search passes type checking" do
      typed = check!(~s|search(node, amenity: "cafe");|)
      assert [{:bare_output, _, _}] = typed
    end

    test "bare search infers correct type" do
      typed = check!(~s|search(node, amenity: "cafe");|)
      [{:bare_output, _expr, pos}] = typed
      assert pos.type == :point_set
    end

    test "bare expression counts as output" do
      check!(~s|$a = boundary(name: "Berlin"); search(node).within($a);|)
    end

    test "multiple bare expressions produce error" do
      errors =
        check_errors(~s|search(amenity: "cafe"); search(amenity: "bar");|)

      error = Enum.find(errors, &(&1.message =~ "only one simple output"))
      assert error.line == 1
      assert error.col == 26
      assert error.severity == :error
      assert error.hint =~ "named outputs"
    end

    test "mixing bare and named output produces error" do
      errors =
        check_errors(~s|search(amenity: "cafe"); $$.foo = search(amenity: "bar");|)

      error = Enum.find(errors, &(&1.message =~ "cannot mix simple output"))
      assert error.line == 1
      assert error.col == 26
      assert error.severity == :error
      assert error.hint =~ "named outputs"
    end

    test "mixing bare and $$ produces error" do
      errors =
        check_errors(~s|search(amenity: "cafe"); $$ = search(amenity: "bar");|)

      error = Enum.find(errors, &(&1.message =~ "only one simple output"))
      assert error.line == 1
      assert error.col == 1
      assert error.severity == :error
      assert error.hint =~ "named outputs"
    end
  end

  # ── Union type inference ──────────────────────────────────────────

  describe "union type inference" do
    test "same types preserve type" do
      assert output_type(~s|$$ = search(node, amenity: "cafe") + search(node, amenity: "bar");|) ==
               :point_set
    end

    test "mixed types produce :geo_set" do
      assert output_type(~s|$$ = search(node, amenity: "cafe") + search(way, highway: "primary");|) ==
               :geo_set
    end

    test "difference preserves left operand type" do
      assert output_type(~s|$$ = search(node, amenity: "cafe") - search(node, amenity: "bar");|) ==
               :point_set
    end
  end

  # ── Filter method ─────────────────────────────────────────────────

  describe "filter method" do
    test ".filter() in valid chain position passes" do
      check!(~s|$$ = search(node, amenity: "cafe").filter(cuisine: "italian").limit(10);|)
    end

    test ".filter() after transform is valid (relaxed ordering)" do
      check!(~s|$$ = search(node, amenity: "cafe").buffer(50).filter(cuisine: "italian");|)
    end
  end

  # ── Error quality ─────────────────────────────────────────────────

  describe "error quality" do
    test "errors have line and col" do
      errors = check_errors(~s|$$ = search(node).within($missing);|)
      error = Enum.find(errors, &(&1.message =~ "undefined"))
      assert error.line == 1
      assert error.col == 25
      assert error.severity == :error
      assert error.hint =~ "define it first"
    end

    test "errors have descriptive messages" do
      errors =
        check_errors(
          ~s|$r = route(origin: point(0, 0), destination: point(1, 1)); $$ = search(node).within($r);|
        )

      error = Enum.find(errors, &(&1.message =~ "`.within()`"))
      assert error.line == 1
      assert error.severity == :error
      assert error.message =~ "Route"
      assert error.hint =~ "around"
    end

    test "errors have hints" do
      errors = check_errors(~s|$$ = search(node).offset(10);|)
      error = Enum.find(errors, &(&1.message =~ "`.offset()`"))
      assert error.line == 1
      assert error.severity == :error
      assert error.hint != nil
      assert error.hint =~ "limit"
      assert error.hint =~ ".limit(n)"
    end

    test "multiple errors returned for multiple issues" do
      errors =
        check_errors(~s|$$ = search(node).limit(10).buffer(50).within($missing);|)

      assert length(errors) >= 2

      # Verify each error has proper structure
      for error <- errors do
        assert error.line == 1
        assert error.col >= 1
        assert error.severity == :error
        assert is_binary(error.message)
      end
    end

    test "errors sorted by line/col" do
      errors =
        check_errors(~s|$$ = search(node).limit(10).buffer(50).within($missing);|)

      positions = Enum.map(errors, &{&1.line, &1.col})
      assert positions == Enum.sort(positions)

      # Verify specific ordering: buffer error, within error, undefined var error
      assert Enum.at(errors, 0).col == 29
      assert Enum.at(errors, 1).col == 40
      assert Enum.at(errors, 2).col == 47
    end
  end

  # ── Basic pass-through ───────────────────────────────────────────

  describe "basic pass-through" do
    test "simple query passes type checking" do
      check!(~s|$$ = search(node, amenity: "cafe");|)
    end
  end

  # ── expr_type/1 ───────────────────────────────────────────────────

  describe "expr_type/1" do
    test "extracts type from search node" do
      assert output_expr_type(~s|$$ = search(node, amenity: "cafe");|) == :point_set
    end

    test "extracts type from variable assignment" do
      typed = check!(~s|$p = point(0, 0); $$ = $p;|)
      {:var_assign, _, expr, _} = Enum.find(typed, &match?({:var_assign, _, _, _}, &1))
      assert TypeChecker.expr_type(expr) == :point
    end
  end

  # ── Bracket references ──────────────────────────────────────────

  describe "bracket references" do
    test "$var[attr] with defined variable passes" do
      check!(~s|$stops = search(node, highway: "bus_stop"); $$ = $stops[ref];|)
    end

    test "$var[attr] with undefined variable errors" do
      errors = check_errors(~s|$$ = $unknown[ref];|)

      error = Enum.find(errors, &String.contains?(&1.message, "undefined variable"))
      assert error.line == 1
      assert error.col == 6
      assert error.severity == :error
      assert error.message =~ "$unknown"
      assert error.hint =~ "define it first"
    end

    test "$var[attr] on geo_set produces value_set type" do
      assert output_expr_type(~s|$stops = search(node); $$ = $stops[ref];|) == :value_set
    end

    test "$var[attr] on geo_element produces scalar type" do
      assert output_expr_type(~s|$stop = search(node).first(); $$ = $stop[ref];|) == :scalar
    end
  end

  # ── Join methods ────────────────────────────────────────────────

  describe "join methods" do
    test "member_of with defined variable passes" do
      check!(~s|$route = search(relation, route: "bus"); $$ = search(node).member_of($route);|)
    end

    test "member_of with undefined variable errors" do
      errors = check_errors(~s|$$ = search(node).member_of($nope);|)

      error = Enum.find(errors, &String.contains?(&1.message, "undefined variable"))
      assert error.line == 1
      assert error.col == 29
      assert error.severity == :error
      assert error.hint =~ "define it first"
    end

    test "member_of with inline search passes" do
      check!(~s|$$ = search(node, highway: "bus_stop").member_of(search(relation, route: "bus"));|)
    end

    test "has_member with defined variable passes" do
      check!(~s|$stops = search(node); $$ = search(relation).has_member($stops);|)
    end

    test "member_of returns same type as input" do
      assert output_expr_type(~s|$route = search(relation); $$ = search(node).member_of($route);|) ==
               :point_set
    end
  end

  # ── Narrowing methods ──────────────────────────────────────────

  describe "narrowing methods" do
    test ".first() transforms geo_set to geo_element" do
      assert output_expr_type(~s|$$ = search(node, amenity: "cafe").first();|) == :geo_element
    end

    test ".last() transforms geo_set to geo_element" do
      assert output_expr_type(~s|$$ = search(node).last();|) == :geo_element
    end

    test ".first().first() errors — can't narrow an element" do
      errors = check_errors(~s|$$ = search(node).first().first();|)

      error = Enum.find(errors, &String.contains?(&1.message, "already a single element"))
      assert error.line == 1
      assert error.col == 27
      assert error.severity == :error
      assert error.message =~ ".first()"
    end

    test ".index() requires positive integer" do
      errors = check_errors(~s|$$ = search(node).index(0);|)

      error = Enum.find(errors, &String.contains?(&1.message, "positive integer"))
      assert error.line == 1
      assert error.col == 19
      assert error.severity == :error
      assert error.hint =~ ".index(3)"
    end

    test ".index(3) passes" do
      check!(~s|$$ = search(node).index(3);|)
    end
  end

  # ── Plan 1: Core gaps ──────────────────────────────────────────

  describe "intersection type checking" do
    test "intersection of same types preserves type" do
      type =
        output_type("""
        $a = search(node, amenity: "cafe");
        $b = search(node, cuisine: "italian");
        $$ = $a & $b;
        """)

      assert type == :point_set
    end

    test "intersection of different types yields geo_set" do
      type =
        output_type("""
        $a = search(node, amenity: "cafe");
        $b = search(way, highway: "primary");
        $$ = $a & $b;
        """)

      assert type == :geo_set
    end
  end

  describe "directive type checking" do
    test "valid #bbox directive passes" do
      check!("""
      #bbox(47, 10, 48, 11);
      $$ = search(node, amenity: "cafe");
      """)
    end

    test "valid #filter directive passes" do
      check!("""
      #filter(amenity: *);
      $$ = search(node);
      """)
    end

    test "valid #limit directive passes" do
      check!("""
      #limit(10);
      $$ = search(node, amenity: "cafe");
      """)
    end

    test "valid #within directive with area passes" do
      check!("""
      #within(boundary(name: "Berlin"));
      $$ = search(node, amenity: "cafe");
      """)
    end
  end

  describe "geom output mode" do
    test ".geom() type checks as terminal" do
      check!(~s|$$ = search(node, amenity: "cafe").geom();|)
    end
  end

  describe "expression filter type checking" do
    test "filter_expr passes type checking" do
      check!(~s|$$ = search(node).filter(t["amenity"] == "cafe");|)
    end

    test "filter_expr with geometry function" do
      check!(~s|$$ = search(way).filter(length() > 5000);|)
    end

    test "filter_expr with logical operators" do
      check!(~s|$$ = search(way).filter(length() > 5000 && is_closed());|)
    end

    test "filter_expr with number coercion" do
      check!(~s|$$ = search(node).filter(number(t["lanes"]) >= 2);|)
    end

    test "filter_expr preserves chain type" do
      assert output_type(~s|$$ = search(node).filter(id() > 100);|) == :point_set
    end

    test "filter_expr on geo_set preserves type" do
      assert output_type(~s|$$ = search().filter(length() > 1000);|) == :geo_set
    end

    test "filter_expr cannot follow terminal" do
      errors = check_errors(~s|$$ = search(node).count().filter(id() > 1);|)
      assert errors != []

      error = hd(errors)
      assert error.line == 1
      assert error.col == 27
      assert error.severity == :error
      assert error.message =~ "cannot follow"
      assert error.message =~ ".count()"
      assert error.hint =~ "before the output mode"
    end
  end

  # ── Aggregation type checking ──────────────────────────────────

  describe "aggregation type checking" do
    test "group_by must be followed by aggregation terminal" do
      errors = check_errors(~s|$$ = search(node).group_by(t["amenity"]).ids();|)
      assert errors != []

      error =
        Enum.find(errors, fn e ->
          e.message =~ "cannot be applied to GroupedSet"
        end)

      assert error.line == 1
      assert error.col == 42
      assert error.severity == :error
      assert error.message =~ ".ids()"
      assert error.hint == nil
    end

    test "group_by followed by count is valid" do
      check!(~s|$$ = search(node, amenity: *).group_by(t["amenity"]).count();|)
    end

    test "group_by followed by sum is valid" do
      check!(
        ~s|$$ = search(node, amenity: "cafe").group_by(t["cuisine"]).sum(number(t["capacity"]));|
      )
    end

    test "group_by followed by avg is valid" do
      check!(
        ~s|$$ = search(node, amenity: "cafe").group_by(t["cuisine"]).avg(number(t["rating"]));|
      )
    end

    test "aggregation without group_by passes" do
      check!(~s|$$ = search(node, amenity: "cafe").sum(number(t["capacity"]));|)
    end

    test "nothing can follow an aggregation terminal" do
      errors =
        check_errors(~s|$$ = search(node).sum(number(t["capacity"])).limit(10);|)

      assert errors != []

      error = hd(errors)
      assert error.line == 1
      assert error.col == 46
      assert error.severity == :error
      assert error.message =~ "cannot follow"
      assert error.message =~ ".sum()"
      assert error.hint =~ "before the output mode"
    end

    test "filter method cannot be applied to grouped_set" do
      errors =
        check_errors(~s|$$ = search(node).group_by(t["amenity"]).filter(name: "test");|)

      assert errors != []

      error =
        Enum.find(errors, fn e ->
          e.message =~ "cannot be applied to GroupedSet"
        end)

      assert error.line == 1
      assert error.col == 42
      assert error.severity == :error
      assert error.message =~ ".filter()"
      assert error.hint == nil
    end
  end
end
