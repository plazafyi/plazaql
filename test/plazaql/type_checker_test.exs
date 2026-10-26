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
      assert var_type(~s|$g = geocode(query: "Berlin"); $$ = $g;|, "$g") == :point_set
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
      assert error.col == 26
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

  describe "route options" do
    @route ~s|route(origin: point(40.71, -74.00), destination: point(40.75, -73.98)|

    test "valid depart_at, traffic_model and exclude pass" do
      check!(
        @route <>
          ~s|, depart_at: "2026-03-16T08:00:00Z", traffic_model: "optimistic", exclude: ["toll", "unpaved"]);|
      )

      check!(@route <> ~s|, depart_at: "now", exclude: "ferry,motorway");|)
    end

    test "an unknown traffic_model is rejected with the allowed values" do
      [error] = check_errors(@route <> ~s|, traffic_model: "psychic");|)

      assert error.message =~
               ~s|`traffic_model:` must be one of "best_guess", "optimistic", "pessimistic"|
    end

    test "unknown exclude values are rejected, in either form" do
      [error] = check_errors(@route <> ~s|, exclude: ["toll", "stairs"]);|)
      assert error.message =~ ~s|unknown `exclude:` value "stairs"|
      assert error.hint =~ ~s|"motorway"|

      [error] = check_errors(@route <> ~s|, exclude: "toll,stairs");|)
      assert error.message =~ ~s|"stairs"|
    end

    test "depart_at must be a string" do
      [error] = check_errors(@route <> ~s|, depart_at: 8);|)
      assert error.message =~ "`depart_at:` must be an ISO 8601 datetime string"
    end

    test "ev_route checks the same options" do
      [error] =
        check_errors(
          ~s|ev_route(origin: point(40.71, -74.00), destination: point(42.36, -71.06), battery: 60000, exclude: ["stairs"]);|
        )

      assert error.message =~ "stairs"
    end

    test "steps, verbal, lang and units pass with valid values" do
      check!(@route <> ~s|, steps: true, verbal: true, lang: "fr", units: "mi");|)
      check!(@route <> ~s|, steps: true, lang: "pt-BR");|)
      check!(@route <> ~s|, steps: false, lang: "zh_Hans");|)
    end

    test "an unsupported lang is rejected with the supported codes" do
      [error] = check_errors(@route <> ~s|, steps: true, lang: "tlh");|)
      assert error.message =~ ~s|unsupported `lang:` "tlh"|
      assert error.hint =~ "fr"
      assert error.hint =~ "ja"

      [error] = check_errors(@route <> ~s|, lang: 7);|)
      assert error.message =~ "`lang:` must be a language tag string"
    end

    test "units must be km or mi, steps and verbal booleans" do
      [error] = check_errors(@route <> ~s|, units: "furlongs");|)
      assert error.message =~ ~s|`units:` must be "km" or "mi"|

      [error] = check_errors(@route <> ~s|, steps: "yes");|)
      assert error.message == "invalid `steps:` for `route()`"
      assert error.hint == "true or false"

      [error] =
        check_errors(
          ~s|ev_route(origin: point(40.71, -74.00), destination: point(42.36, -71.06), battery: 60000, verbal: 1);|
        )

      assert error.message == "invalid `verbal:` for `ev_route()`"
      assert error.hint == "true or false"
    end
  end

  describe "truck options" do
    @route ~s|route(origin: point(40.71, -74.00), destination: point(40.75, -73.98)|

    test "route, isochrone and matrix take the vehicle with mode truck" do
      check!(
        @route <>
          ~s|, mode: "truck", height: 4.1, width: 2.5, length: 16.5, weight: 30, axle_load: 9.5, axle_count: 5, hazmat: true);|
      )

      check!(~s|isochrone(center: point(40.71, -74.00), time: 600, mode: "truck", height: 3.8);|)

      check!(
        ~s|matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], mode: "truck", weight: 40);|
      )

      check!(@route <> ~s|, mode: "truck");|)
    end

    test "vehicle options need mode truck" do
      [error] = check_errors(@route <> ~s|, height: 4.1);|)
      assert error.message =~ ~s|need `mode: "truck"`|

      [error] = check_errors(@route <> ~s|, mode: "auto", hazmat: true);|)
      assert error.message =~ ~s|need `mode: "truck"`|

      # A mode from a variable is checked when the query runs.
      check!(~s|$m = "truck"; | <> @route <> ~s|, mode: $m, height: 4.1);|)
    end

    test "other computations have no truck options" do
      [error] =
        check_errors(
          ~s|centroid(locations: [point(48.858, 2.294), point(48.87, 2.35)], height: 4.0);|
        )

      assert error.message =~ "`centroid()` has no truck options"
    end

    test "values must have the right type" do
      [error] = check_errors(@route <> ~s|, mode: "truck", height: "tall");|)
      assert error.message == "`height:` must be a positive number (metres)"

      [error] = check_errors(@route <> ~s|, mode: "truck", weight: 0);|)
      assert error.message == "`weight:` must be a positive number (tonnes)"

      check!(@route <> ~s|, mode: "truck", axle_count: 5.0);|)

      [error] = check_errors(@route <> ~s|, mode: "truck", axle_count: 2.5);|)
      assert error.message == "`axle_count:` must be a whole number of axles"

      [error] = check_errors(@route <> ~s|, mode: "truck", hazmat: "yes");|)
      assert error.message == "`hazmat:` must be `true` or `false`"
    end
  end

  describe "centroid options" do
    @locations ~s|locations: [point(48.858, 2.294), point(48.87, 2.35)]|

    test "valid metric and exclude pass, and the result is a PointSet" do
      check!(~s|centroid(#{@locations}, metric: "distance", exclude: ["toll"]);|)
      check!(~s|$m = centroid(#{@locations}); search(node, amenity: "cafe").around(300, $m);|)
    end

    test "an unknown metric is rejected" do
      [error] = check_errors(~s|centroid(#{@locations}, metric: "vibes");|)
      assert error.message =~ ~s|`metric:` must be one of "time", "distance"|
    end

    test "exclude is checked like route()'s" do
      [error] = check_errors(~s|centroid(#{@locations}, exclude: "stairs");|)
      assert error.message =~ "stairs"
    end
  end

  describe "expansion options" do
    @route_args ~s|origin: point(48.858, 2.294), destination: point(48.87, 2.35)|

    test "each action passes" do
      check!(~s|expansion(action: "route", #{@route_args});|)
      check!(~s|expansion(action: "isochrone", center: point(48.858, 2.294), time: [300, 600]);|)

      check!(
        ~s|expansion(action: "matrix", origins: [point(48.858, 2.294)], destinations: [point(48.87, 2.35)], expansion_properties: ["distance"]);|
      )
    end

    test "action is required and must be known" do
      [error] = check_errors(~s|expansion(#{@route_args});|)
      assert error.message =~ "requires `action:`"

      [error] = check_errors(~s|expansion(action: "teleport", #{@route_args});|)
      assert error.message =~ ~s|`action:` must be one of "route", "isochrone", "matrix"|
    end

    test "unknown expansion_properties are rejected" do
      [error] =
        check_errors(
          ~s|expansion(action: "route", #{@route_args}, expansion_properties: ["duration", "vibes"]);|
        )

      assert error.message =~ ~s|unknown `expansion_properties:` value "vibes"|
      assert error.hint =~ ~s|"cumulative_cost"|
    end
  end

  describe "point-list computation keywords" do
    test "matrix takes origins and destinations as point lists" do
      check!(
        ~s|matrix(origins: [point(40.71, -74.00), point(40.72, -74.01)], destinations: [point(40.75, -73.98)]);|
      )
    end

    test "map_match and elevation take points" do
      check!(~s|map_match(points: [point(40.71, -74.00), point(40.72, -74.01)]);|)
      check!(~s|elevation(points: [point(40.71, -74.00)]);|)
    end
  end

  describe "geocoding" do
    test "structured geocode and filters pass" do
      check!(
        ~s|geocode(address: "1600 Pennsylvania Ave", locality: "Washington", region: "DC", postalcode: 20500, country: "US");|
      )

      check!(~s|geocode("Main St", layers: "address,poi", boundary_gid: "osm:relation:62422");|)
      check!(~s|autocomplete("Caf", layers: ["poi"], boundary_gid: "osm:way:42");|)
    end

    test "dataset keywords are accepted where they apply" do
      check!(~s|geocode("Main St", datasets: ["census-places", "all"], layers: "dataset");|)
      check!(~s|geocode(locality: "Springfield", datasets: "plaza", dataset_name_field: "title");|)
      check!(~s|autocomplete("Gold", datasets: ["my-stores"]);|)
      check!(~s|reverse_geocode(point(38.9, -77.0), datasets: ["census-tracts"]);|)

      check!(
        ~s|route(origin: point(38.8, -77.1), destination: point(38.8, -77.0), avoid_datasets: ["flood-zones"]);|
      )

      check!(~s|isochrone(center: point(38.8, -77.1), time: 600, avoid_datasets: "flood-zones");|)

      check!(
        ~s|matrix(origins: [point(38.8, -77.1)], destinations: [point(38.8, -77.0)], avoid_datasets: ["a"]);|
      )
    end

    test "dataset keywords are rejected on computations that don't take them" do
      [error] =
        check_errors(
          ~s|route(origin: point(38.8, -77.1), destination: point(38.8, -77.0), datasets: ["x"]);|
        )

      assert error.message == "`route()` does not accept `datasets:`"
      assert error.hint =~ "`avoid_datasets:`"

      [error] = check_errors(~s|geocode("Main St", avoid_datasets: ["x"]);|)
      assert error.message == "`geocode()` does not accept `avoid_datasets:`"

      [error] = check_errors(~s|reverse_geocode(point(38.9, -77.0), dataset_name_field: "title");|)
      assert error.message == "`reverse_geocode()` does not accept `dataset_name_field:`"
    end

    test "dataset keyword values must be strings" do
      [error] = check_errors(~s|geocode("Main St", datasets: 5);|)
      assert error.message == "`datasets:` must be a string or a list of strings"

      [error] = check_errors(~s|geocode("Main St", datasets: ["a", 5]);|)
      assert error.message == "`datasets:` list items must be strings"

      [error] = check_errors(~s|geocode("Main St", datasets: ["a"], dataset_name_field: 5);|)
      assert error.message == "`dataset_name_field:` must be a string"
    end

    test "geocode needs query text or a component" do
      [error] = check_errors(~s|geocode(country: "US");|)
      assert error.message =~ "needs an address string"
    end

    test "unknown layers are rejected with the supported values" do
      [error] = check_errors(~s|geocode("Main St", layers: ["venue"]);|)
      assert error.message =~ ~s|unknown `layers:` value "venue"|
      assert error.hint =~ ~s|"poi"|
    end

    test "boundary_gid must be a way or relation GID" do
      [error] = check_errors(~s|geocode("Main St", boundary_gid: "osm:node:1");|)
      assert error.message =~ "invalid `boundary_gid:`"
    end

    test "components must be strings" do
      [error] = check_errors(~s|geocode(locality: 42);|)
      assert error.message =~ "`locality:` must be a string"
    end

    test "place_lookup returns a point set and checks its GIDs" do
      assert output_type(~s|$$ = place_lookup("osm:node:1", "osm:address:7");|) == :point_set

      [error] = check_errors(~s|place_lookup("node/1");|)
      assert error.message =~ ~s|invalid GID "node/1"|

      [error] = check_errors(~s|place_lookup();|)
      assert error.message =~ "at least one GID"

      [error] = check_errors(~s|place_lookup("osm:node:12345678901234567890");|)
      assert error.message =~ "invalid GID"

      check!(~s|place_lookup("osm:node:9223372036854775807");|)

      [error] =
        check_errors(~s|geocode("Cafe", boundary_gid: "osm:relation:12345678901234567890");|)

      assert error.message =~ "invalid `boundary_gid:`"
    end
  end
end
