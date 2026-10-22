defmodule PlazaQL.CensusTest do
  @moduledoc """
  Census-support language features: `overlap_fraction(geom)` (expression),
  `.overlap_fraction(geom)` (computed column), `$var` / `$$.name` / `bbox(...)`
  geometry in spatial predicates, and `reverse_geocode(point, include: ...)`.
  """
  use ExUnit.Case, async: true

  alias PlazaQL.Compiler
  alias PlazaQL.Formatter
  alias PlazaQL.NotCompilable
  alias PlazaQL.Parser
  alias PlazaQL.Schema
  alias PlazaQL.SQL
  alias PlazaQL.TypeChecker

  @iso ~s|$area = isochrone(center: point(40.7484, -73.9856), time: 900, mode: "foot");|
  @poly "polygon(point(40.70, -74.02), point(40.70, -73.97), point(40.75, -73.97), point(40.75, -74.02))"
  @ring [
    {-74.02, 40.70},
    {-73.97, 40.70},
    {-73.97, 40.75},
    {-74.02, 40.75},
    {-74.02, 40.70}
  ]

  defp parse!(source) do
    {:ok, ast} = Parser.parse(source)
    ast
  end

  defp check!(source) do
    case TypeChecker.check(parse!(source)) do
      {:ok, typed} -> typed
      {:error, errors} -> flunk("Type check failed:\n#{inspect(errors, pretty: true)}")
    end
  end

  defp check_errors(source) do
    case TypeChecker.check(parse!(source)) do
      {:ok, _} -> flunk("Expected type errors but check passed for: #{source}")
      {:error, errors} -> errors
    end
  end

  defp plans(source) do
    {:ok, %{plans: plans}} = Compiler.compile(check!(source))
    plans
  end

  defp last_plan(source), do: List.last(plans(source))

  defp format(source), do: Formatter.format(parse!(source))

  # Finds the first overlap_fraction node anywhere in a term
  defp find_overlap(term) when is_tuple(term) do
    case term do
      {:geom_func, :overlap_fraction, _ref, _pos} -> term
      _ -> find_overlap(Tuple.to_list(term))
    end
  end

  defp find_overlap(term) when is_list(term), do: Enum.find_value(term, &find_overlap/1)
  defp find_overlap(term) when is_map(term), do: find_overlap(Map.values(term))
  defp find_overlap(_), do: nil

  # ── overlap_fraction(geom) — parser ─────────────────────────────

  describe "overlap_fraction() AST" do
    test "polygon argument becomes a closed lng/lat ring" do
      ast = parse!(~s|search(node).filter(overlap_fraction(#{@poly}) > 0.5);|)
      assert {:geom_func, :overlap_fraction, {:polygon, [@ring]}, %{line: 1}} = find_overlap(ast)
    end

    test "already-closed polygon is not closed twice" do
      closed =
        "polygon(point(40.70, -74.02), point(40.70, -73.97), point(40.75, -73.97), point(40.75, -74.02), point(40.70, -74.02))"

      ast = parse!(~s|search(node).filter(overlap_fraction(#{closed}) > 0.5);|)
      assert {:geom_func, :overlap_fraction, {:polygon, [@ring]}, _} = find_overlap(ast)
    end

    test "bbox argument becomes a closed rectangle ring" do
      ast = parse!(~s|search(node).sort(overlap_fraction(bbox(40.70, -74.02, 40.75, -73.97)));|)
      assert {:geom_func, :overlap_fraction, {:polygon, [@ring]}, _} = find_overlap(ast)
    end

    test "$var argument becomes a set_ref without the $" do
      ast = parse!(@iso <> ~s|search(node).sum(number(t["population"]) * overlap_fraction($area));|)

      assert {:geom_func, :overlap_fraction, {:set_ref, "area"}, _} = find_overlap(ast)
    end

    test "$$.name argument becomes a set_ref with the $$. prefix" do
      ast = parse!(~s|search(node).filter(overlap_fraction($$.area) > 0.1);|)
      assert {:geom_func, :overlap_fraction, {:set_ref, "$$.area"}, _} = find_overlap(ast)
    end

    test "keyword-argument (filter_function_call) form" do
      ast = parse!(~s|search(node).sort(by: overlap_fraction($area), order: :desc);|)

      assert [
               {:bare_output,
                {:search, :node, [],
                 [
                   {:method, :sort_expr, {:geom_func, :overlap_fraction, {:set_ref, "area"}, _},
                    :desc, _}
                 ], _}, _}
             ] = ast
    end

    test "unsupported argument is kept as {:invalid, ast}" do
      ast = parse!(~s|search(node).filter(overlap_fraction(point(1, 2)) > 0);|)

      assert {:geom_func, :overlap_fraction, {:invalid, {:point, 1, 2, _}}, _} =
               find_overlap(ast)
    end
  end

  # ── overlap_fraction(geom) — type checker ───────────────────────

  describe "overlap_fraction() type checking" do
    test "accepted in .sum, .filter, .sort, .group_by, .avg" do
      for method <- [
            ~s|.sum(number(t["population"]) * overlap_fraction($area))|,
            ~s|.filter(overlap_fraction($area) > 0.5)|,
            ~s|.sort(overlap_fraction($area), order: :desc)|,
            ~s|.group_by(overlap_fraction($area)).count()|,
            ~s|.avg(overlap_fraction(bbox(40.70, -74.02, 40.75, -73.97)))|,
            ~s|.max(overlap_fraction(#{@poly}))|
          ] do
        check!(@iso <> ~s|search(dataset("census-tracts")).intersects($area)#{method};|)
      end
    end

    test "accepted with a named output reference" do
      check!(
        ~s|$$.area = isochrone(center: point(40.7, -73.9), time: 600);\n| <>
          ~s|$$.tracts = search(dataset("census-tracts")).filter(overlap_fraction($$.area) > 0.5);|
      )
    end

    test "undefined variable produces the standard undefined-variable error" do
      [error] = check_errors(~s|search(node).sum(overlap_fraction($nope));|)
      assert error.message == "undefined variable `$nope`"
      assert error.hint =~ "define it first"
    end

    test "undefined output variable produces the standard error" do
      [error] = check_errors(~s|search(node).sum(overlap_fraction($$.nope));|)
      assert error.message == "undefined output variable `$$.nope`"
    end

    test "rejects a point argument with a hint" do
      [error] = check_errors(~s|search(node).filter(overlap_fraction(point(1, 2)) > 0);|)

      assert error.message =~
               "overlap_fraction()` expects a polygon(...), bbox(...), or a variable holding polygons"

      assert error.hint =~ "bbox(s, w, n, e)"
    end

    test "rejects a variable that cannot hold polygons" do
      [error] =
        check_errors(~s|$p = point(1, 2);\nsearch(node).filter(overlap_fraction($p) > 0);|)

      assert error.message =~ "variable holding polygons, but `$p` is Point"
    end
  end

  # ── overlap_fraction(geom) — compiler ───────────────────────────

  describe "overlap_fraction() compilation" do
    test "passes through untouched in aggregate_expr" do
      plan =
        last_plan(
          @iso <>
            ~s|search(dataset("census-tracts")).intersects($area).sum(number(t["population"]) * overlap_fraction($area));|
        )

      assert plan.output_mode == :sum

      assert {:bin_op, :mul, {:coerce_func, :number, {:tag_access, "population", _}, _},
              {:geom_func, :overlap_fraction, {:set_ref, "area"}, _}, _} = plan.aggregate_expr

      assert plan.spatial_filter == {:predicate, :intersects, {:set_ref, "area"}}
    end

    test "passes through in filter_exprs, sort_expr, and group_by" do
      plan =
        last_plan(
          @iso <>
            ~s|search(node).filter(overlap_fraction($area) > 0.5).sort(overlap_fraction(#{@poly}), order: :desc);|
        )

      assert [{:bin_op, :gt, {:geom_func, :overlap_fraction, {:set_ref, "area"}, _}, _, _}] =
               plan.filter_exprs

      assert {{:geom_func, :overlap_fraction, {:polygon, [@ring]}, _}, :desc} = plan.sort_expr

      plan = last_plan(@iso <> ~s|search(node).group_by(overlap_fraction($area)).count();|)
      assert {:geom_func, :overlap_fraction, {:set_ref, "area"}, _} = plan.group_by
    end
  end

  # ── .overlap_fraction(geom) — computed column ───────────────────

  describe ".overlap_fraction() computed column" do
    test "polygon argument" do
      plan = last_plan(~s|search(dataset("census-tracts")).overlap_fraction(#{@poly});|)

      assert plan.computed_columns == [
               {:overlap_fraction, {:geom_func, :overlap_fraction, {:polygon, [@ring]}, nil}}
             ]
    end

    test "bbox, $var, and $$.name arguments" do
      plan = last_plan(~s|search(node).overlap_fraction(bbox(40.70, -74.02, 40.75, -73.97));|)

      assert [{:overlap_fraction, {:geom_func, :overlap_fraction, {:polygon, [@ring]}, nil}}] =
               plan.computed_columns

      plan = last_plan(@iso <> ~s|search(node).intersects($area).overlap_fraction($area).area();|)

      assert plan.computed_columns == [
               {:overlap_fraction, {:geom_func, :overlap_fraction, {:set_ref, "area"}, nil}},
               {:area_m2, {:geom_func, :area, nil}}
             ]

      plan =
        last_plan(
          ~s|$$.zone = isochrone(center: point(40.7, -73.9), time: 600);\n| <>
            ~s|$$.tracts = search(node).overlap_fraction($$.zone);|
        )

      assert plan.computed_columns == [
               {:overlap_fraction, {:geom_func, :overlap_fraction, {:set_ref, "$$.zone"}, nil}}
             ]
    end

    test "is freely orderable (computed category)" do
      check!(@iso <> ~s|search(node).overlap_fraction($area).within($area).limit(5);|)
    end

    test "rejects unsupported arguments" do
      [error] = check_errors(~s|search(node).overlap_fraction(point(1, 2));|)
      assert error.message =~ "expects a polygon(...), bbox(...), or a variable holding polygons"

      [error] = check_errors(~s|search(node).overlap_fraction();|)
      assert error.message =~ "takes exactly one geometry argument"
    end

    test "undefined variable is reported once" do
      [error] = check_errors(~s|search(node).overlap_fraction($nope);|)
      assert error.message == "undefined variable `$nope`"
    end
  end

  # ── Spatial predicates with variable geometry ───────────────────

  describe "spatial predicates with variable geometry" do
    test "$var compiles to a set_ref for every predicate" do
      for method <-
            ~w(within intersects contains crosses touches not_within not_intersects not_contains)a do
        plan =
          last_plan(
            ~s|$r = route(origin: point(40.7, -74.0), destination: point(40.8, -73.9));\n| <>
              ~s|$area = boundary(name: "Manhattan");\n| <>
              ~s|$$ = search(way).#{method}(#{if method == :crosses, do: "$r", else: "$area"});|
          )

        expected = if method == :crosses, do: "r", else: "area"
        assert plan.spatial_filter == {:predicate, method, {:set_ref, expected}}
      end
    end

    test "$$.name compiles to a set_ref with the $$. prefix" do
      plan =
        last_plan(
          ~s|$$.zone = isochrone(center: point(40.7, -73.9), time: 600);\n| <>
            ~s|$$.cafes = search(node, amenity: "cafe").within($$.zone);|
        )

      assert plan.spatial_filter == {:predicate, :within, {:set_ref, "$$.zone"}}
    end

    test "bbox compiles to a closed lng/lat polygon ring" do
      plan = last_plan(~s|search(node).intersects(bbox(40.70, -74.02, 40.75, -73.97));|)
      assert plan.spatial_filter == {:predicate, :intersects, {:polygon, [@ring]}}
    end

    test "SQL generation refuses unresolved set refs" do
      plan = last_plan(@iso <> ~s|search(node).within($area);|)

      assert {:error, %NotCompilable{reason: :unresolved_geometry_ref, plan: ^plan} = e} =
               SQL.to_sql(plan, Schema.new())

      assert Exception.message(e) =~ ~s|.within() references set "area"|
    end
  end

  # ── SQL generation ──────────────────────────────────────────────

  describe "overlap_fraction SQL" do
    test "polygon ref in an aggregate" do
      plan =
        last_plan(
          ~s|search(node).sum(number(t["population"]) * overlap_fraction(bbox(40.70, -74.02, 40.75, -73.97)));|
        )

      {:ok, query} = SQL.to_sql(plan, Schema.new())

      assert query.sql =~
               "(ST_Area(ST_Intersection(geom, ST_GeomFromEWKT($2))::geography) / NULLIF(ST_Area(geom::geography), 0))"

      assert "SRID=4326;POLYGON((-74.02 40.7, -73.97 40.7, -73.97 40.75, -74.02 40.75, -74.02 40.7))" in query.params
    end

    test "computed column alias" do
      plan = last_plan(~s|search(node).overlap_fraction(#{@poly});|)
      {:ok, query} = SQL.to_sql(plan, Schema.new())
      assert query.sql =~ ~r/NULLIF\(ST_Area\(geom::geography\), 0\)\) AS overlap_fraction/
    end

    test "set ref is not compilable" do
      # Compiled without type checking: the executor normally resolves $$.x first
      {:ok, ast} = Parser.parse(~s|search(node).overlap_fraction($$.x);|)
      {:ok, %{plans: [plan]}} = Compiler.compile(ast)

      assert {:error, %NotCompilable{reason: :unresolved_geometry_ref}} =
               SQL.to_sql(plan, Schema.new())
    end
  end

  # ── Formatter ───────────────────────────────────────────────────

  describe "formatter round-trips" do
    for {name, source} <- [
          {"$var",
           ~s|$area = isochrone(center: point(40.7484, -73.9856), time: 900, mode: "foot");\n\nsearch(node).sum(number(t["population"]) * overlap_fraction($area));\n|},
          {"$$.name", ~s|search(node).filter(overlap_fraction($$.area) > 0.5);\n|},
          {"bbox",
           ~s|search(node)\n  .sort(overlap_fraction(bbox(40.7, -74.02, 40.75, -73.97)), order: :desc);\n|},
          {"polygon",
           ~s|search(node)\n  .avg(overlap_fraction(polygon(point(1, 2), point(3, 4), point(5, 7), point(1, 2))));\n|},
          {"method", ~s|search(node).overlap_fraction($$.area);\n|}
        ] do
      @source source
      test "#{name}" do
        assert format(@source) == @source
        assert format(format(@source)) == @source
      end
    end

    test "unclosed polygon is closed on format" do
      assert format(
               ~s|search(way).max(overlap_fraction(polygon(point(1, 2), point(3, 4), point(5, 7))));|
             ) ==
               ~s|search(way)\n  .max(overlap_fraction(polygon(point(1, 2), point(3, 4), point(5, 7), point(1, 2))));\n|
    end
  end

  # ── reverse_geocode(include:) ───────────────────────────────────

  describe "reverse_geocode include:" do
    test "string form compiles into computation params" do
      plan = last_plan(~s|reverse_geocode(point(40.7484, -73.9856), include: "census");|)

      assert plan.computation ==
               {:reverse_geocode, %{point: {40.7484, -73.9856}, include: "census"}}
    end

    test "list form compiles to a list of strings" do
      plan = last_plan(~s|reverse_geocode(point(40.7484, -73.9856), include: ["census"]);|)

      assert plan.computation ==
               {:reverse_geocode, %{point: {40.7484, -73.9856}, include: ["census"]}}
    end

    test "unknown include values are rejected with a hint" do
      [error] = check_errors(~s|reverse_geocode(point(1, 2), include: "zip");|)
      assert error.message =~ ~s|unknown `include:` value "zip"|
      assert error.hint == ~s|supported values: "census"|

      [error] = check_errors(~s|reverse_geocode(point(1, 2), include: ["census", "x"]);|)
      assert error.message =~ ~s|"x"|
    end

    test "formats back to source" do
      source = ~s|reverse_geocode(point(40.7484, -73.9856), include: "census");\n|
      assert format(source) == source
    end
  end

  # ── examples/census.pql ─────────────────────────────────────────

  @examples_path Path.join([__DIR__, "..", "..", "examples", "census.pql"])

  test "examples/census.pql parses, type-checks, and compiles statement by statement" do
    statements =
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

    assert length(statements) >= 5

    for source <- statements do
      {:ok, ast} = Parser.parse(source)
      assert {:ok, typed} = TypeChecker.check(ast), "type check failed: #{source}"
      assert {:ok, _} = Compiler.compile(typed), "compile failed: #{source}"
    end
  end
end
