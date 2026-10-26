defmodule PlazaQL.RestParityTest do
  @moduledoc """
  Language forms that mirror Plaza REST parameters: per-computation keyword
  allowlists, positional computation arguments, `.crosses(linestring(...))`,
  `.include()`, `.geometry()`, `.sort(by: ...)` and the `p["key"]` accessor.
  """
  use ExUnit.Case, async: true

  defp plan!(source) do
    {:ok, %{plans: [plan | _]}} = PlazaQL.compile(source)
    plan
  end

  defp plan_list(source) do
    {:ok, %{plans: plans}} = PlazaQL.compile(source)
    plans
  end

  defp error!(source) do
    {:error, [%PlazaQL.Error{} = error | _]} = PlazaQL.compile(source)
    error
  end

  @od "origin: point(38.8, -77.1), destination: point(38.8, -77.09)"

  describe "computation keyword allowlist" do
    test "an unknown keyword names the computation and lists what it accepts" do
      error = error!("route(#{@od}, foo: 1);")
      assert error.message == "`route()` does not accept `foo:`"
      assert error.hint =~ "`depart_at:`"
      assert error.line == 1
    end

    test "a keyword valid elsewhere is refused on a computation that ignores it" do
      assert error!("route(#{@od}, points: [point(1, 2)]);").message ==
               "`route()` does not accept `points:`"

      assert error!("nearest(point: point(1, 2), type: \"node\");").message ==
               "`nearest()` does not accept `type:`"
    end

    test "every REST option of route and isochrone compiles" do
      assert {:route, params} =
               plan!(
                 "route(#{@od}, mode: \"foot\", steps: true, alternatives: 2, " <>
                   "depart_at: \"now\", traffic_model: \"pessimistic\", exclude: [\"toll\"]);"
               ).computation

      assert params.steps == true
      assert params.alternatives == 2

      assert error!("isochrone(center: point(1, 2), time: 300, contours: [300]);").message ==
               "`isochrone()` does not accept `contours:`"

      assert {:optimize, %{roundtrip: false}} =
               plan!("optimize(point(1, 2), point(3, 4), roundtrip: false);").computation
    end
  end

  describe "positional computation arguments" do
    test "elevation(point) and elevation(p1, p2)" do
      assert {:elevation, %{point: {1, 2}}} = plan!("elevation(point(1, 2));").computation

      assert {:elevation, %{points: [{1, 2}, {3, 4}]}} =
               plan!("elevation(point(1, 2), point(3, 4));").computation
    end

    test "elevation_profile(linestring) profiles the line's vertices" do
      assert {:elevation_profile, %{points: [{1, 2}, {3, 4}]}} =
               plan!("elevation_profile(linestring(point(1, 2), point(3, 4)));").computation
    end

    test "optimize(p1, p2, p3) takes the points as waypoints" do
      assert {:optimize, %{waypoints: [{1, 2}, {3, 4}, {5, 6}], mode: "auto"}} =
               plan!("optimize(point(1, 2), point(3, 4), point(5, 6), mode: \"auto\");").computation
    end

    test "map_match(linestring) takes the line's vertices as the trace" do
      assert {:map_match, %{points: [{1, 2}, {3, 4}], mode: "auto"}} =
               plan!("map_match(linestring(point(1, 2), point(3, 4)), mode: \"auto\");").computation
    end

    test "positionals a computation can't use are errors, not dropped" do
      assert error!("matrix(point(1, 2));").message =~ "`matrix()` takes keyword arguments"
      assert error!("elevation(\"x\");").message =~ "`elevation()` takes point(lat, lng)"

      assert error!("route(point(1, 2), point(3, 4), point(5, 6));").message =~
               "`route()` takes an origin and a destination point"

      assert error!(~s|$a = geocode("x"); route($a, point(3, 4));|).message =~
               "use origin: and destination: keywords"
    end
  end

  describe "spatial predicates" do
    test ".crosses(linestring(...)) filters against the line, lng/lat ordered" do
      assert {:predicate, :crosses, {:linestring, [{-77.1, 38.8}, {-77.09, 38.8}]}} =
               plan!("search(way).crosses(linestring(point(38.8, -77.1), point(38.8, -77.09)));").spatial_filter
    end
  end

  describe "inline boundary arguments" do
    test "run as a step, like a boundary variable" do
      {:ok, inline} =
        PlazaQL.compile(~s|search(node, amenity: "cafe").within(boundary(name: "Paris"));|)

      {:ok, variable} =
        PlazaQL.compile(~s|$b = boundary(name: "Paris"); search(node, amenity: "cafe").within($b);|)

      assert [{"boundary#1", boundary}] = inline.steps
      assert boundary.element_types == [:boundary]
      assert [{"b", ^boundary}] = variable.steps
      assert [%{spatial_filter: {:predicate, :within, {:set_ref, "boundary#1"}}}] = inline.plans
    end

    test "geometry: is the same as the positional argument" do
      {:ok, kw} =
        PlazaQL.compile(~s|$b = boundary(name: "Paris"); search(node).within(geometry: $b);|)

      {:ok, pos} = PlazaQL.compile(~s|$b = boundary(name: "Paris"); search(node).within($b);|)

      assert [%{spatial_filter: {:predicate, :within, {:set_ref, "b"}}}] = kw.plans
      assert kw.plans == pos.plans

      assert [%{spatial_filter: {:predicate, :crosses, {:linestring, [_, _]}}}] =
               plan_list("search(way).crosses(geometry: linestring(point(1, 2), point(3, 4)));")
    end

    test "an inline computation or search runs as a step" do
      {:ok, result} =
        PlazaQL.compile(
          ~s|search(way, leisure: "park").within(isochrone(center: point(1, 2), time: 900));|
        )

      assert [{"computation#1", %{computation: {:isochrone, _}}}] = result.steps
      assert [%{spatial_filter: {:predicate, :within, {:set_ref, "computation#1"}}}] = result.plans

      {:ok, result} =
        PlazaQL.compile(~s|search(way).intersects(geometry: search(way, waterway: "river"));|)

      assert [{"search#1", _}] = result.steps
    end

    test "each inline boundary gets its own step" do
      {:ok, result} =
        PlazaQL.compile(~s"""
        $$.a = search(node).within(boundary(name: "A"));
        $$.b = search(node).not_within(boundary(name: "B"));
        """)

      assert Enum.map(result.steps, &elem(&1, 0)) == ["boundary#1", "boundary#2"]
    end
  end

  describe "output shape" do
    test ".include() takes the REST output.include values" do
      plan = plan!(~s|search(node).include("bbox", "center", "distance");|)
      assert plan.output_options.include == MapSet.new([:bbox, :center, :distance])
    end

    test ".include() with another value is an error" do
      assert error!(~s|search(node).include("nodes");|).message =~
               ~s|`.include()` takes "bbox", "center" or "distance"|
    end

    test ".geometry(false) drops geometry; .geometry(true) keeps it" do
      assert plan!("search(node).geometry(false);").output_options.geometry == false
      assert plan!("search(node).geometry(true);").output_options.geometry == true
      assert error!("search(node).geometry(1);").message =~ "`.geometry()` takes true or false"
    end
  end

  describe "sorting" do
    test ".sort(by: :osm_id) and .sort(by: :name)" do
      assert plan!("search(node).sort(by: :osm_id);").output_options.sort == :osm_id
      assert plan!("search(node).sort(by: :name);").output_options.sort == :name
    end

    test "sorting by a string literal is an error, not a no-op" do
      assert error!(~s|search(node).sort("osm_id");|).message =~ "sorts by a constant string"
    end
  end

  describe "p[\"key\"]" do
    test "reads the same value as t[\"key\"]" do
      p_plan = plan!(~s|search(node).filter(number(p["pop"]) > 3).sort(p["name"]);|)
      t_plan = plan!(~s|search(node).filter(number(t["pop"]) > 3).sort(t["name"]);|)

      strip = fn plan -> {strip_pos(plan.filter_exprs), strip_pos(plan.sort_expr)} end
      assert strip.(p_plan) == strip.(t_plan)
    end

    test "formats as t[\"key\"]" do
      {:ok, ast} = PlazaQL.parse(~s|search(node).filter(p["a"] == "x");|)
      assert PlazaQL.Formatter.format(ast) =~ ~s|t["a"]|
    end
  end

  defp strip_pos(term) when is_map(term) and not is_struct(term),
    do:
      if(Map.has_key?(term, :line),
        do: :pos,
        else: Map.new(term, fn {k, v} -> {k, strip_pos(v)} end)
      )

  defp strip_pos(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&strip_pos/1)
    |> List.to_tuple()
  end

  defp strip_pos(term) when is_list(term), do: Enum.map(term, &strip_pos/1)
  defp strip_pos(term), do: term
end
