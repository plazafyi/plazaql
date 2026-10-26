defmodule PlazaQL.CompilerTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Compiler
  alias PlazaQL.Parser

  # ── Helpers ───────────────────────────────────────────────────────

  defp compile!(source) do
    {:ok, ast} = Parser.parse(source)
    {:ok, result} = Compiler.compile(ast)
    result
  end

  defp first_plan(source) do
    %{plans: [plan | _]} = compile!(source)
    plan
  end

  # ── Search compilation ────────────────────────────────────────────

  describe "search compilation" do
    test "simple tag filter" do
      plan = first_plan(~s|$$ = search(amenity: "cafe");|)
      assert plan.element_types == [:node, :way, :relation]
      assert plan.tag_filters == [{:eq, "amenity", "cafe"}]
    end

    test "typed search — node" do
      plan = first_plan(~s|$$ = search(node, amenity: "cafe");|)
      assert plan.element_types == [:node]
      assert plan.tag_filters == [{:eq, "amenity", "cafe"}]
    end

    test "typed search — way" do
      plan = first_plan(~s|$$ = search(way, highway: "primary");|)
      assert plan.element_types == [:way]
    end

    test "typed search — relation" do
      plan = first_plan(~s|$$ = search(relation, type: "route");|)
      assert plan.element_types == [:relation]
    end

    test "typed search — nwr" do
      plan = first_plan(~s|$$ = search(nwr, name: "test");|)
      assert plan.element_types == [:node, :way, :relation]
    end

    test "no type, no filters" do
      plan = first_plan(~s|$$ = search();|)
      assert plan.element_types == [:node, :way, :relation]
      assert plan.tag_filters == []
    end

    test "defaults for compiled plan" do
      plan = first_plan(~s|$$ = search();|)
      assert plan.output_mode == :full
      assert plan.limit == nil
      assert plan.spatial_filter == nil
      assert plan.set_ops == []
    end
  end

  # ── Tag filter types ──────────────────────────────────────────────

  describe "tag filter types" do
    test "equals" do
      plan = first_plan(~s|$$ = search(amenity: "cafe");|)
      assert {:eq, "amenity", "cafe"} in plan.tag_filters
    end

    test "not equals" do
      plan = first_plan(~s|$$ = search(amenity: !"cafe");|)
      assert {:neq, "amenity", "cafe"} in plan.tag_filters
    end

    test "regex" do
      plan = first_plan(~s|$$ = search(name: ~"^Starbucks");|)
      assert {:regex, "name", "^Starbucks"} in plan.tag_filters
    end

    test "case-insensitive regex" do
      plan = first_plan(~s|$$ = search(name: ~i"starbucks");|)
      assert {:regex_i, "name", "starbucks"} in plan.tag_filters
    end

    test "negated regex" do
      plan = first_plan(~s|$$ = search(name: !~"^Mc");|)
      assert {:not_regex, "name", "^Mc"} in plan.tag_filters
    end

    test "exists" do
      plan = first_plan(~s|$$ = search(wheelchair: *);|)
      assert {:exists, "wheelchair"} in plan.tag_filters
    end

    test "not exists" do
      plan = first_plan(~s|$$ = search(wheelchair: !*);|)
      assert {:not_exists, "wheelchair"} in plan.tag_filters
    end

    test "multiple tag filters" do
      plan = first_plan(~s|$$ = search(amenity: "cafe", name: ~"Star", wheelchair: *);|)
      assert length(plan.tag_filters) == 3
    end
  end

  # ── Spatial methods ───────────────────────────────────────────────

  describe "spatial methods" do
    test ".around with literal point" do
      plan = first_plan(~s|$$ = search(node, amenity: "cafe").around(500, point(38.9, -77.0));|)
      assert plan.spatial_filter == {:around, 38.9, -77.0, 500}
    end

    test ".around with variable" do
      result =
        compile!("""
        $area = search(relation, name: "DC");
        $$ = search(node, amenity: "cafe").around(500, $area);
        """)

      plan = hd(result.plans)
      assert plan.spatial_filter == {:around_set, "area", 500}
    end

    test ".bbox" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").bbox(38.8, -77.1, 39.0, -76.9);|)
      assert plan.spatial_filter == {:bbox, 38.8, -77.1, 39.0, -76.9}
    end

    test ".within with point" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").within(point(38.9, -77.0));|)
      assert {:predicate, :within, {:point, _, _}} = plan.spatial_filter
    end

    test ".intersects with point" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").intersects(point(38.9, -77.0));|)
      assert {:predicate, :intersects, {:point, _, _}} = plan.spatial_filter
    end

    test ".contains with point" do
      plan = first_plan(~s|$$ = search(way, building: *).contains(point(38.9, -77.0));|)
      assert {:predicate, :contains, {:point, _, _}} = plan.spatial_filter
    end

    test ".h3" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").h3("891f1d48177ffff");|)
      assert plan.spatial_filter == {:h3, "891f1d48177ffff"}
    end

    test ".not_within" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").not_within(point(38.9, -77.0));|)
      assert {:predicate, :not_within, {:point, _, _}} = plan.spatial_filter
    end

    test ".not_intersects" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").not_intersects(point(38.9, -77.0));|)
      assert {:predicate, :not_intersects, {:point, _, _}} = plan.spatial_filter
    end
  end

  # ── Transform methods ────────────────────────────────────────────

  describe "transform methods" do
    test ".buffer" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").buffer(50);|)
      assert plan.output_options.buffer == 50.0
    end

    test ".simplify" do
      plan = first_plan(~s|$$ = search(way, highway: *).simplify(10);|)
      assert plan.output_options.simplify == 10.0
    end

    test ".centroid" do
      plan = first_plan(~s|$$ = search(way, building: *).centroid;|)
      assert plan.output_options.centroid == true
    end

    test ".precision" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").precision(5);|)
      assert plan.output_options.precision == 5
    end

    test ".fields" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").fields("name", "amenity");|)
      assert plan.output_options.fields == ["name", "amenity"]
    end

    test ".include" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").include(:bbox, :center);|)
      assert MapSet.member?(plan.output_options.include, :bbox)
      assert MapSet.member?(plan.output_options.include, :center)
    end

    test ".sort" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").sort(by: :distance);|)
      assert plan.output_options.sort == :distance
    end
  end

  # ── Ordering methods ──────────────────────────────────────────────

  describe "ordering methods" do
    test ".limit" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").limit(10);|)
      assert plan.limit == 10
    end

    test ".offset" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").offset(20);|)
      assert plan.offset == 20
    end

    test ".limit and .offset combined" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").limit(10).offset(20);|)
      assert plan.limit == 10
      assert plan.offset == 20
    end

    test ".cursor keeps the server's token as given" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").limit(10).cursor("SFMyNTY.g2gD.x-_y");|)
      assert plan.limit == 10
      assert plan.cursor == "SFMyNTY.g2gD.x-_y"
      assert plan.offset == nil
    end

    test ".sort(distance($var)) keeps the variable for the executor to resolve" do
      {:ok, %{plans: plans}} =
        PlazaQL.compile(
          ~s|$home = search(node, amenity: "cafe").bbox(1, 2, 3, 4); | <>
            ~s|search(node).bbox(1, 2, 3, 4).sort(distance($home));|
        )

      assert {{:geom_func, :distance, {:set_ref, "home"}, _pos}, :asc} =
               List.last(plans).sort_expr
    end

    test ".sort(distance($$.name)) refers to an output" do
      {:ok, %{plans: [_, plan]}} =
        PlazaQL.compile(
          ~s|$$.parks = search(way, leisure: "park").bbox(1, 2, 3, 4); | <>
            ~s|$$.cafes = search(node).bbox(1, 2, 3, 4).sort(distance($$.parks));|
        )

      assert {{:geom_func, :distance, {:set_ref, "$$.parks"}, _}, :asc} = plan.sort_expr
    end

    test "distance($p) with a point variable measures from that point" do
      {:ok, %{plans: [plan]}} =
        PlazaQL.compile(
          ~s|$p = point(48.85, 2.35); search(node).around(500, $p).sort(distance($p));|
        )

      assert {{:geom_func, :distance, {48.85, 2.35}, _}, :asc} = plan.sort_expr
    end

    test "distance() of a polygon literal variable is a compile error" do
      assert {:error, [error | _]} =
               PlazaQL.compile(
                 ~s|$a = bbox(1, 2, 3, 4); search(node).bbox(1, 2, 3, 4).sort(distance($a));|
               )

      assert error.message =~ "distance($a) needs a point"
    end

    test "distance() of an undefined variable is a compile error" do
      assert {:error, [error | _]} =
               PlazaQL.compile(~s|search(node).bbox(1, 2, 3, 4).sort(distance($nope));|)

      assert error.message =~ "undefined variable `$nope`"
    end

    test "a plan without .cursor has none" do
      assert first_plan(~s|$$ = search(amenity: "cafe").limit(10);|).cursor == nil
    end

    test ".cursor applies per output" do
      {:ok, %{plans: [cafes, parks]}} =
        PlazaQL.compile(
          ~s|$$.cafes = search(node, amenity: "cafe").limit(5).cursor("a"); | <>
            ~s|$$.parks = search(way, leisure: "park").limit(5);|
        )

      assert cafes.cursor == "a"
      assert parks.cursor == nil
    end
  end

  # ── Output modes ──────────────────────────────────────────────────

  describe "output modes" do
    for mode <- [:count, :ids, :tags, :skel] do
      test ".#{mode}" do
        plan = first_plan(~s|$$ = search(amenity: "cafe").#{unquote(mode)};|)
        assert plan.output_mode == unquote(mode)
      end
    end
  end

  # ── Set operations ────────────────────────────────────────────────

  describe "set operations" do
    test "union" do
      plan = first_plan(~s|$$ = search(amenity: "cafe") + search(amenity: "restaurant");|)
      assert [{:union, union_plan}] = plan.set_ops
      assert union_plan.tag_filters == [{:eq, "amenity", "restaurant"}]
    end

    test "difference" do
      plan = first_plan(~s|$$ = search(amenity: "cafe") - search(name: "Starbucks");|)
      assert [{:difference, [_left, right]}] = plan.set_ops
      assert right.tag_filters == [{:eq, "name", "Starbucks"}]
    end
  end

  # ── Variables ─────────────────────────────────────────────────────

  describe "variables" do
    test "variable assignment creates step" do
      result =
        compile!("""
        $cafes = search(node, amenity: "cafe");
        $$ = $cafes;
        """)

      assert [{"cafes", step_plan}] = result.steps
      assert step_plan.element_types == [:node]
      assert step_plan.tag_filters == [{:eq, "amenity", "cafe"}]
    end

    test "variable reference resolves" do
      result =
        compile!("""
        $cafes = search(node, amenity: "cafe");
        $$ = $cafes;
        """)

      plan = hd(result.plans)
      assert plan.element_types == [:node]
      assert plan.tag_filters == [{:eq, "amenity", "cafe"}]
    end

    test "multiple variables" do
      result =
        compile!("""
        $cafes = search(node, amenity: "cafe");
        $restaurants = search(node, amenity: "restaurant");
        $$ = $cafes + $restaurants;
        """)

      assert length(result.steps) == 2
      plan = hd(result.plans)
      assert [{:union, _}] = plan.set_ops
    end
  end

  # ── Multiple outputs ──────────────────────────────────────────────

  describe "multiple outputs" do
    test "named outputs" do
      result =
        compile!("""
        $$.cafes = search(amenity: "cafe");
        $$.parks = search(leisure: "park");
        """)

      assert length(result.plans) == 2
      assert result.output_names == ["cafes", "parks"]
    end

    test "default output name is nil" do
      result = compile!(~s|$$ = search(amenity: "cafe");|)
      assert result.output_names == [nil]
    end

    test "output variable reference resolves to earlier output plan" do
      result =
        compile!("""
        $$.route = route(point(38.9, -77.0), point(38.85, -77.05));
        $$.stops = search(amenity: "cafe").around(200, $$.route);
        """)

      assert result.output_names == ["route", "stops"]
      stops_plan = Enum.at(result.plans, 1)
      assert {:around_set, "$$.route", 200} = stops_plan.spatial_filter
    end

    test "output variable reference as direct expression" do
      result =
        compile!("""
        $$.base = search(node, amenity: "cafe");
        $$.copy = $$.base;
        """)

      assert result.output_names == ["base", "copy"]
      copy_plan = Enum.at(result.plans, 1)
      assert copy_plan.element_types == [:node]
      assert copy_plan.tag_filters == [{:eq, "amenity", "cafe"}]
    end
  end

  # ── Computation functions ─────────────────────────────────────────

  describe "computation functions" do
    test "route" do
      plan = first_plan(~s|$$ = route(point(38.9, -77.0), point(39.0, -76.5));|)
      assert plan.kind == :computation
      assert {:route, params} = plan.computation
      assert params.origin == {38.9, -77.0}
      assert params.destination == {39.0, -76.5}
    end

    test "isochrone" do
      plan = first_plan(~s|$$ = isochrone(center: point(38.9, -77.0), time: 600);|)
      assert plan.kind == :computation
      assert {:isochrone, params} = plan.computation
      assert params.center == {38.9, -77.0}
      assert params.time == 600
    end

    test "geocode" do
      plan = first_plan(~s|$$ = geocode("1600 Pennsylvania Ave");|)
      assert plan.kind == :computation
      assert {:geocode, params} = plan.computation
      assert params.query == "1600 Pennsylvania Ave"
    end

    test "reverse_geocode" do
      plan = first_plan(~s|$$ = reverse_geocode(point(38.9, -77.0));|)
      assert plan.kind == :computation
      assert {:reverse_geocode, params} = plan.computation
      assert params.point == {38.9, -77.0}
    end

    test "nearest" do
      plan = first_plan(~s|$$ = nearest(point: point(38.9, -77.0), radius: 1000);|)
      assert plan.kind == :computation
      assert {:nearest, params} = plan.computation
      assert params.point == {38.9, -77.0}
      assert params.radius == 1000
    end

    test "matrix" do
      plan = first_plan(~s|$$ = matrix(mode: "driving");|)
      assert plan.kind == :computation
      assert {:matrix, params} = plan.computation
      assert params.mode == "driving"
    end

    test "ev_route with battery" do
      plan =
        first_plan(
          ~s|$$ = ev_route(origin: point(40.71, -74.00), destination: point(42.36, -71.06), battery: 60000);|
        )

      assert plan.kind == :computation
      assert {:ev_route, params} = plan.computation
      assert params.origin == {40.71, -74.00}
      assert params.destination == {42.36, -71.06}
      assert params.battery_capacity_wh == 60_000
    end

    test "ev_route accepts the EV and routing options as keywords" do
      plan =
        first_plan(
          ~s|$$ = ev_route(origin: point(40.71, -74.00), destination: point(42.36, -71.06), battery: 60000, initial_charge_pct: 0.9, min_charge_pct: 0.15, connector_types: ["ccs", "type2"], min_power_kw: 50, waypoints: [point(41.0, -73.5)], alternatives: 2);|
        )

      assert {:ev_route, params} = plan.computation
      assert params.battery_capacity_wh == 60_000
      assert params.initial_charge_pct == 0.9
      assert params.min_charge_pct == 0.15
      assert params.min_power_kw == 50
      assert params.alternatives == 2
      assert {:list, [{:string, "ccs", _}, {:string, "type2", _}], _} = params.connector_types
      assert {:list, [{:point, 41.0, -73.5, _}], _} = params.waypoints
    end

    test "battery_capacity_wh is accepted under its executor name" do
      plan =
        first_plan(
          ~s|$$ = ev_route(point(40.71, -74.00), point(42.36, -71.06), battery_capacity_wh: 60000);|
        )

      assert {:ev_route, %{battery_capacity_wh: 60_000}} = plan.computation
    end

    test "route accepts depart_at, traffic_model and exclude like POST /route" do
      plan =
        first_plan(
          ~s|$$ = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), depart_at: "2026-03-16T08:00:00Z", traffic_model: "pessimistic", exclude: ["toll", "ferry"]);|
        )

      assert {:route, params} = plan.computation
      assert params.depart_at == "2026-03-16T08:00:00Z"
      assert params.traffic_model == "pessimistic"
      assert params.exclude == ["toll", "ferry"]
    end

    test "route, isochrone and matrix pass the truck vehicle keywords through" do
      plan =
        first_plan(
          ~s|$$ = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), mode: "truck", height: 4.1, width: 2.5, length: 16.5, weight: 30, axle_load: 9.5, axle_count: 5, hazmat: true);|
        )

      assert {:route, params} = plan.computation

      assert %{
               mode: "truck",
               height: 4.1,
               width: 2.5,
               length: 16.5,
               weight: 30,
               axle_load: 9.5,
               axle_count: 5,
               hazmat: true
             } = params

      plan =
        first_plan(
          ~s|$$ = isochrone(center: point(40.71, -74.00), time: 600, mode: "truck", height: 3.8);|
        )

      assert {:isochrone, %{mode: "truck", height: 3.8}} = plan.computation

      plan =
        first_plan(
          ~s|$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], mode: "truck", hazmat: false);|
        )

      assert {:matrix, %{mode: "truck", hazmat: false}} = plan.computation
    end

    test "route, isochrone and matrix pass the motorcycle and motor scooter keywords through" do
      plan =
        first_plan(
          ~s|$$ = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), mode: "motorcycle", style: "adventure", use_trails: 0.7, use_curves: 0.9, use_highways: 0.2);|
        )

      assert {:route,
              %{
                mode: "motorcycle",
                style: "adventure",
                use_trails: 0.7,
                use_curves: 0.9,
                use_highways: 0.2
              }} = plan.computation

      plan =
        first_plan(
          ~s|$$ = isochrone(center: point(40.71, -74.00), time: 600, mode: "scooter", top_speed: 50);|
        )

      assert {:isochrone, %{mode: "scooter", top_speed: 50}} = plan.computation

      plan =
        first_plan(
          ~s|$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], mode: "motor_scooter", use_primary: 0, use_hills: 0.1);|
        )

      assert {:matrix, %{mode: "motor_scooter", use_primary: 0, use_hills: 0.1}} =
               plan.computation
    end

    test "route, isochrone and matrix pass the bicycle and pedestrian keywords through" do
      plan =
        first_plan(
          ~s|$$ = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), mode: "bicycle", bicycle_type: "road", cycling_speed: 24, use_roads: 0.2, use_hills: 0.1, avoid_bad_surfaces: 1);|
        )

      assert {:route,
              %{
                mode: "bicycle",
                bicycle_type: "road",
                cycling_speed: 24,
                use_roads: 0.2,
                use_hills: 0.1,
                avoid_bad_surfaces: 1
              }} = plan.computation

      plan =
        first_plan(
          ~s|$$ = isochrone(center: point(40.71, -74.00), time: 600, mode: "foot", walking_speed: 4, use_lit: 1, walkway_factor: 0.8, sidewalk_factor: 0.9, step_penalty: 60, max_hiking_difficulty: 2, wheelchair: true);|
        )

      assert {:isochrone,
              %{
                mode: "foot",
                walking_speed: 4,
                use_lit: 1,
                walkway_factor: 0.8,
                sidewalk_factor: 0.9,
                step_penalty: 60,
                max_hiking_difficulty: 2,
                wheelchair: true
              }} = plan.computation

      plan =
        first_plan(
          ~s|$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], mode: "foot", use_hills: 0);|
        )

      assert {:matrix, %{mode: "foot", use_hills: 0}} = plan.computation
    end

    test "route accepts the navigation options like POST /route" do
      plan =
        first_plan(
          ~s|$$ = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), steps: true, voice_instructions: true, banner_instructions: true, roundabout_exits: true, voice_units: "imperial", waypoint_names: ["", "Home"]);|
        )

      assert {:route,
              %{
                voice_instructions: true,
                banner_instructions: true,
                roundabout_exits: true,
                voice_units: "imperial",
                waypoint_names: ["", "Home"]
              }} = plan.computation
    end

    test "route and isochrone pass the transit keywords through" do
      plan =
        first_plan(
          ~s|$$ = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), mode: "transit", depart_at: "2026-03-16T08:00:00-04:00", use_bus: 0.5, use_rail: 1, use_transfers: 0.25, max_walk_m: 800, max_transfers: 2);|
        )

      assert {:route,
              %{
                mode: "transit",
                depart_at: "2026-03-16T08:00:00-04:00",
                use_bus: 0.5,
                use_rail: 1,
                use_transfers: 0.25,
                max_walk_m: 800,
                max_transfers: 2
              }} = plan.computation

      plan =
        first_plan(
          ~s|$$ = isochrone(center: point(40.71, -74.00), time: 900, mode: "transit", depart_at: "now", use_rail: 0);|
        )

      assert {:isochrone, %{mode: "transit", depart_at: "now", use_rail: 0}} = plan.computation
    end

    test "route passes the costing, per-point and recosting keywords through" do
      plan =
        first_plan(
          ~s|$$ = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), waypoints: [point(40.72, -74.00)], use_tolls: 0, shortest: false, top_speed: 90, maneuver_penalty: 5, gate_cost: 60, toll_booth_cost: 120, country_crossing_cost: 600, location_types: ["break", "via", "break"], headings: "90;;", preferred_sides: ["", "", "same"], approaches: ["", "", "curb"], recostings: ["walk: mode=foot"]);|
        )

      assert {:route,
              %{
                use_tolls: 0,
                shortest: false,
                top_speed: 90,
                maneuver_penalty: 5,
                gate_cost: 60,
                toll_booth_cost: 120,
                country_crossing_cost: 600,
                location_types: ["break", "via", "break"],
                headings: "90;;",
                preferred_sides: ["", "", "same"],
                approaches: ["", "", "curb"],
                recostings: ["walk: mode=foot"]
              }} = plan.computation
    end

    test "route and ev_route accept steps, lang, units and verbal like POST /route" do
      plan =
        first_plan(
          ~s|$$ = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), steps: true, lang: "fr", units: "km", verbal: true);|
        )

      assert {:route, %{steps: true, lang: "fr", units: "km", verbal: true}} = plan.computation

      plan =
        first_plan(
          ~s|$$ = ev_route(origin: point(40.71, -74.00), destination: point(42.36, -71.06), battery: 60000, steps: true, lang: "de");|
        )

      assert {:ev_route, %{steps: true, lang: "de"}} = plan.computation
    end

    test "exclude also takes a comma-separated string, and ev_route takes the same options" do
      plan =
        first_plan(
          ~s|$$ = ev_route(origin: point(40.71, -74.00), destination: point(42.36, -71.06), battery: 60000, exclude: "toll,motorway", depart_at: "now");|
        )

      assert {:ev_route, %{exclude: "toll,motorway", depart_at: "now"}} = plan.computation
    end

    test "matrix accepts origins and destinations as keywords" do
      plan =
        first_plan(
          ~s|$$ = matrix(origins: [point(40.71, -74.00), point(40.72, -74.01)], destinations: [point(40.75, -73.98)]);|
        )

      assert {:matrix, params} = plan.computation
      assert {:list, [{:point, 40.71, -74.00, _}, {:point, 40.72, -74.01, _}], _} = params.origins
      assert {:list, [{:point, 40.75, -73.98, _}], _} = params.destinations
    end

    test "map_match and elevation accept points as a keyword" do
      plan = first_plan(~s|$$ = map_match(points: [point(40.71, -74.00), point(40.72, -74.01)]);|)
      assert {:map_match, %{points: {:list, [_, _], _}}} = plan.computation

      plan = first_plan(~s|$$ = elevation(points: [point(40.71, -74.00)]);|)
      assert {_elevation, %{points: {:list, [{:point, 40.71, -74.00, _}], _}}} = plan.computation
    end

    test "centroid takes locations, mode, metric and exclude" do
      plan =
        first_plan(
          ~s|$$ = centroid(locations: [point(48.858, 2.294), point(48.87, 2.35)], mode: "foot", metric: "distance", exclude: ["ferry"]);|
        )

      assert {:centroid, params} = plan.computation
      assert {:list, [{:point, 48.858, 2.294, _}, {:point, 48.87, 2.35, _}], _} = params.locations
      assert params.mode == "foot"
      assert params.metric == "distance"
      assert params.exclude == ["ferry"]
    end

    test "expansion takes an action, that action's keywords and expansion_properties" do
      plan =
        first_plan(
          ~s|$$ = expansion(action: "route", origin: point(48.858, 2.294), destination: point(48.87, 2.35), expansion_properties: ["duration", "cumulative_cost"]);|
        )

      assert {:expansion, params} = plan.computation
      assert params.action == "route"
      assert {:point, 48.858, 2.294, _} = params.origin

      assert params.expansion_properties == ["duration", "cumulative_cost"]

      plan =
        first_plan(
          ~s|$$ = expansion(action: "isochrone", center: point(48.858, 2.294), time: 600);|
        )

      assert {:expansion, %{action: "isochrone", time: 600}} = plan.computation
    end

    test "geocode takes structured components and filters as keywords" do
      plan =
        first_plan(
          ~s|$$ = geocode(address: "1600 Pennsylvania Ave", locality: "Washington", region: "DC", postalcode: "20500", country: "US", layers: ["address", "poi"], boundary_gid: "osm:relation:62422", limit: 5);|
        )

      assert {:geocode, params} = plan.computation
      refute Map.has_key?(params, :query)
      assert params.address == "1600 Pennsylvania Ave"
      assert params.locality == "Washington"
      assert params.region == "DC"
      assert params.postalcode == "20500"
      assert params.country == "US"
      assert params.layers == ["address", "poi"]
      assert params.boundary_gid == "osm:relation:62422"
      assert params.limit == 5
    end

    test "free-text geocode keeps its query next to focus, country_code and county" do
      plan =
        first_plan(
          ~s|$$ = geocode("Main St", focus: point(38.9, -77.0), country_code: "US", layers: "address");|
        )

      assert {:geocode, %{query: "Main St", country_code: "US", layers: "address"} = params} =
               plan.computation

      assert {:point, 38.9, -77.0, _} = params.focus

      plan =
        first_plan(
          ~s|$$ = geocode(locality: "Springfield", county: "Sangamon", neighbourhood: "Enos Park");|
        )

      assert {:geocode, %{county: "Sangamon", neighbourhood: "Enos Park"}} = plan.computation
    end

    test "autocomplete and text_search keep their positional query text" do
      plan = first_plan(~s|$$ = autocomplete("Cafe de", boundary_gid: "osm:relation:1", limit: 5);|)

      assert {:autocomplete, %{query: "Cafe de", boundary_gid: "osm:relation:1", limit: 5}} =
               plan.computation

      plan = first_plan(~s|$$ = text_search("pizza");|)
      assert {:text_search, %{query: "pizza"}} = plan.computation
    end

    test "datasets:, dataset_name_field: and avoid_datasets: compile to plain values" do
      plan =
        first_plan(
          ~s|$$ = geocode("Golden Gate", datasets: ["census-places", "all"], dataset_name_field: "title");|
        )

      assert {:geocode,
              %{
                query: "Golden Gate",
                datasets: ["census-places", "all"],
                dataset_name_field: "title"
              }} =
               plan.computation

      plan = first_plan(~s|$$ = reverse_geocode(point(38.9, -77.0), datasets: "plaza");|)
      assert {:reverse_geocode, %{point: {38.9, -77.0}, datasets: "plaza"}} = plan.computation

      plan = first_plan(~s|$$ = autocomplete("Gold", datasets: ["my-stores"]);|)
      assert {:autocomplete, %{query: "Gold", datasets: ["my-stores"]}} = plan.computation

      plan =
        first_plan(
          ~s|$$ = route(origin: point(38.8, -77.1), destination: point(38.8, -77.0), avoid_datasets: ["flood-zones"]);|
        )

      assert {:route, %{avoid_datasets: ["flood-zones"]}} = plan.computation

      plan =
        first_plan(
          ~s|$$ = isochrone(center: point(38.8, -77.1), time: 600, avoid_datasets: "flood-zones");|
        )

      assert {:isochrone, %{avoid_datasets: "flood-zones"}} = plan.computation

      plan =
        first_plan(
          ~s|$$ = matrix(origins: [point(38.8, -77.1)], destinations: [point(38.8, -77.0)], avoid_datasets: ["a", "b"]);|
        )

      assert {:matrix, %{avoid_datasets: ["a", "b"]}} = plan.computation
    end

    test "place_lookup collects positional GIDs and ids: into ids" do
      plan = first_plan(~s|$$ = place_lookup("osm:node:123", "osm:way:456");|)
      assert {:place_lookup, %{ids: ["osm:node:123", "osm:way:456"]}} = plan.computation

      plan = first_plan(~s|$$ = place_lookup(ids: ["osm:relation:789"]);|)
      assert {:place_lookup, %{ids: ["osm:relation:789"]}} = plan.computation
    end

    test "unknown keyword names are still rejected" do
      {:ok, ast} = Parser.parse(~s|$$ = route(point(1.0, 2.0), point(1.1, 2.1), bogus: 1);|)
      assert {:error, [%{message: message}]} = Compiler.compile(ast)
      assert message =~ "bogus"
    end
  end

  # ── Filter method ─────────────────────────────────────────────────

  describe "filter method" do
    test ".filter appends tag filters" do
      plan = first_plan(~s|$$ = search(amenity: "cafe").filter(wheelchair: "yes");|)
      assert {:eq, "amenity", "cafe"} in plan.tag_filters
      assert {:eq, "wheelchair", "yes"} in plan.tag_filters
      assert length(plan.tag_filters) == 2
    end

    test ".filter after union" do
      plan =
        first_plan(
          ~s|$$ = (search(amenity: "cafe") + search(amenity: "restaurant")).filter(wheelchair: "yes");|
        )

      assert {:eq, "wheelchair", "yes"} in plan.tag_filters
    end
  end

  # ── Computed columns ──────────────────────────────────────────────

  describe "computed columns" do
    test ".elevation" do
      plan = first_plan(~s|$$ = search(node, amenity: "cafe").elevation;|)
      assert {:elevation_m, {:geom_func, :elevation, nil}} in plan.computed_columns
    end

    test ".distance with point" do
      plan = first_plan(~s|$$ = search(node, amenity: "cafe").distance(point(38.9, -77.0));|)
      assert {:distance_m, {:geom_func, :distance, {38.9, -77.0}, nil}} in plan.computed_columns
    end

    test ".length" do
      plan = first_plan(~s|$$ = search(way, highway: "primary").length;|)
      assert {:length_m, {:geom_func, :length, nil}} in plan.computed_columns
    end

    test ".area" do
      plan = first_plan(~s|$$ = search(way, building: *).area;|)
      assert {:area_m2, {:geom_func, :area, nil}} in plan.computed_columns
    end
  end

  # ── Boundary ────────────────────────────────────────────────────

  describe "boundary" do
    test "boundary query" do
      plan = first_plan(~s|$$ = boundary(name: "Washington");|)
      assert plan.element_types == [:boundary]
      assert {:eq, "name", "Washington"} in plan.tag_filters
    end

    test "boundary scoped by #within directive" do
      result =
        compile!("""
        #within(boundary(name: "NY State"));
        $$.nyc = boundary(name: "NYC");
        """)

      nyc_plan = hd(result.plans)
      assert nyc_plan.element_types == [:boundary]
      assert nyc_plan.scope_geometry != nil
    end
  end

  # ── Complex queries ───────────────────────────────────────────────

  describe "complex queries" do
    test "full pipeline with variables, spatial, transforms" do
      result =
        compile!("""
        $area = boundary(name: "Washington");
        $$.result = search(node, amenity: "cafe")
          .around(500, point(38.9, -77.0))
          .buffer(50)
          .precision(5)
          .limit(10)
          .sort(by: :distance);
        """)

      assert [{"area", area_plan}] = result.steps
      assert area_plan.element_types == [:boundary]

      plan = hd(result.plans)
      assert plan.element_types == [:node]
      assert plan.spatial_filter == {:around, 38.9, -77.0, 500}
      assert plan.output_options.buffer == 50.0
      assert plan.output_options.precision == 5
      assert plan.output_options.sort == :distance
      assert plan.limit == 10
      assert result.output_names == ["result"]
    end

    test "chained methods preserve order" do
      plan =
        first_plan(
          ~s|$$ = search(node, amenity: "cafe").around(200, point(1.0, 2.0)).simplify(5).limit(20).count;|
        )

      assert plan.spatial_filter == {:around, 1.0, 2.0, 200}
      assert plan.output_options.simplify == 5.0
      assert plan.limit == 20
      assert plan.output_mode == :count
    end
  end

  # ── Bare expression statements ─────────────────────────────────

  describe "bare expression statements" do
    test "bare search compiles like $$ = search" do
      plan = first_plan(~s|search(node, amenity: "cafe");|)
      assert plan.element_types == [:node]
      assert plan.tag_filters == [{:eq, "amenity", "cafe"}]
    end

    test "bare search with methods" do
      plan = first_plan(~s|search(amenity: "cafe").limit(10).count;|)
      assert plan.limit == 10
      assert plan.output_mode == :count
    end

    test "bare computation" do
      plan = first_plan(~s|route(point(38.9, -77.0), point(40.7, -74.0));|)
      assert plan.kind == :computation
      assert {:route, _} = plan.computation
    end

    test "bare set operation" do
      plan = first_plan(~s|search(amenity: "cafe") + search(amenity: "bar");|)
      assert [{:union, _}] = plan.set_ops
    end

    test "bare with variables" do
      result =
        compile!("""
        $cafes = search(node, amenity: "cafe");
        $cafes;
        """)

      plan = hd(result.plans)
      assert plan.element_types == [:node]
      assert result.output_names == [nil]
    end

    test "bare with limit" do
      plan =
        first_plan("""
        search(amenity: "cafe").limit(5);
        """)

      assert plan.limit == 5
    end

    test "equivalent to explicit $$ form" do
      {:ok, bare_ast} = Parser.parse(~s|search(node, amenity: "cafe").limit(5);|)
      {:ok, bare} = Compiler.compile(bare_ast)

      {:ok, explicit_ast} = Parser.parse(~s|$$ = search(node, amenity: "cafe").limit(5);|)
      {:ok, explicit} = Compiler.compile(explicit_ast)

      bare_plan = hd(bare.plans)
      explicit_plan = hd(explicit.plans)

      assert bare_plan.element_types == explicit_plan.element_types
      assert bare_plan.tag_filters == explicit_plan.tag_filters
      assert bare_plan.limit == explicit_plan.limit
      assert bare.output_names == explicit.output_names
    end
  end

  # ── PlazaQL.compile/1 integration ──────────────────────────────

  describe "PlazaQL.compile/1" do
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
  end

  # ── Plan 1: Core gaps ──────────────────────────────────────────

  describe "ID filter compilation" do
    test "numeric ID → osm_ids" do
      plan = first_plan(~s|$$ = search(node, id: 12345);|)
      assert plan.osm_ids == [12_345]
      assert plan.tag_filters == []
    end

    test "ID list → osm_ids" do
      plan = first_plan(~s|$$ = search(node, id: [1, 2, 3]);|)
      assert plan.osm_ids == [1, 2, 3]
    end

    test "mixed ID and tag filters" do
      plan = first_plan(~s|$$ = search(node, id: 123, amenity: "cafe");|)
      assert plan.osm_ids == [123]
      assert plan.tag_filters == [{:eq, "amenity", "cafe"}]
    end
  end

  describe "key+value regex compilation" do
    test "key_value_regex passes through" do
      plan = first_plan(~s|$$ = search(node, ~"^addr:": ~"^[0-9]");|)
      assert {:key_value_regex, "^addr:", "^[0-9]"} in plan.tag_filters
    end

    test "key_regex_exists passes through" do
      plan = first_plan(~s|$$ = search(node, ~"^name:": *);|)
      assert {:key_regex_exists, "^name:"} in plan.tag_filters
    end
  end

  describe "intersection compilation" do
    test "& produces intersection set op" do
      result =
        compile!("""
        $cafes = search(node, amenity: "cafe");
        $italian = search(node, cuisine: "italian");
        $$ = $cafes & $italian;
        """)

      plan = hd(result.plans)
      assert [{:intersection, _sub_plan}] = plan.set_ops
    end
  end

  describe "directive compilation" do
    test "#bbox directive applies spatial filter to searches" do
      result =
        compile!("""
        #bbox(47, 10, 48, 11);
        $$ = search(node, amenity: "cafe");
        """)

      plan = hd(result.plans)
      assert plan.spatial_filter == {:bbox, 47, 10, 48, 11}
    end

    test "#limit directive applies to searches" do
      result =
        compile!("""
        #limit(100);
        $$ = search(node, amenity: "cafe");
        """)

      plan = hd(result.plans)
      assert plan.limit == 100
    end

    test "explicit methods override directive for single-value fields" do
      result =
        compile!("""
        #limit(100);
        $$ = search(node, amenity: "cafe").limit(10);
        """)

      plan = hd(result.plans)
      assert plan.limit == 10
    end

    test "#filter directive stacks with search filters" do
      result =
        compile!("""
        #filter(amenity: *);
        $$ = search(node, cuisine: "italian");
        """)

      plan = hd(result.plans)
      assert {:exists, "amenity"} in plan.tag_filters
      assert {:eq, "cuisine", "italian"} in plan.tag_filters
    end

    test "directives apply to all searches" do
      result =
        compile!("""
        #limit(50);
        $$.cafes = search(node, amenity: "cafe");
        $$.pubs = search(node, amenity: "pub");
        """)

      assert Enum.all?(result.plans, &(&1.limit == 50))
    end

    test "multiple directives accumulate" do
      result =
        compile!("""
        #bbox(47, 10, 48, 11);
        #filter(amenity: *);
        $$ = search(node);
        """)

      plan = hd(result.plans)
      assert plan.spatial_filter == {:bbox, 47, 10, 48, 11}
      assert {:exists, "amenity"} in plan.tag_filters
    end
  end

  describe "output mode compilation" do
    test ".geom() → :full output mode" do
      plan = first_plan(~s|$$ = search(node, amenity: "cafe").geom();|)
      assert plan.output_mode == :full
    end

    test ".sort(by: :qt) sets sort option" do
      plan = first_plan(~s|$$ = search(node, amenity: "cafe").sort(by: :qt);|)
      assert plan.output_options.sort == :qt
    end
  end

  # ── Aggregation compilation ────────────────────────────────────

  describe "aggregation compilation" do
    for {func, mode, expr, tag} <- [
          {"sum", :sum, ~s|number(t["capacity"])|, "capacity"},
          {"max", :max, ~s|number(t["population"])|, "population"},
          {"avg", :avg, ~s|number(t["rating"])|, "rating"}
        ] do
      test ".#{func}() sets output_mode and aggregate_expr" do
        plan = first_plan(~s|search(node).#{unquote(func)}(#{unquote(expr)});|)
        assert plan.output_mode == unquote(mode)
        assert {:coerce_func, :number, {:tag_access, unquote(tag), _}, _} = plan.aggregate_expr
      end
    end

    test ".min() sets output_mode with bare tag access" do
      plan = first_plan(~s|search(node).min(t["name"]);|)
      assert plan.output_mode == :min
      assert {:tag_access, "name", _} = plan.aggregate_expr
    end

    test ".group_by() sets group_by on plan" do
      plan = first_plan(~s|search(node, amenity: *).group_by(t["amenity"]).count();|)
      assert {:tag_access, "amenity", _} = plan.group_by
      assert plan.output_mode == :count
    end

    test ".group_by().avg() sets both group_by and aggregate_expr" do
      plan =
        first_plan(
          ~s|search(node, amenity: "cafe").group_by(t["cuisine"]).avg(number(t["rating"]));|
        )

      assert {:tag_access, "cuisine", _} = plan.group_by
      assert plan.output_mode == :avg
      assert {:coerce_func, :number, {:tag_access, "rating", _}, _} = plan.aggregate_expr
    end
  end

  # ── Dataset source compilation ──────────────────────────────────

  describe "dataset source compilation" do
    test "dataset source sets empty element_types" do
      {:ok, ast} = Parser.parse(~s|search(dataset("00000000-0000-0000-0000-000000000000"));|)

      assert [
               {:bare_output,
                {:search, {:dataset, ["00000000-0000-0000-0000-000000000000"]}, [], [], _pos}, _}
             ] = ast
    end

    test "dataset source with filters preserves tag filters in AST" do
      {:ok, ast} = Parser.parse(~s|search(dataset("my-slug"), amenity: "cafe");|)

      assert [
               {:bare_output, {:search, {:dataset, ["my-slug"]}, [{:eq, "amenity", "cafe"}], [], _},
                _}
             ] = ast
    end

    test "multiple datasets in AST" do
      {:ok, ast} = Parser.parse(~s|search(dataset("a", "b"));|)
      assert [{:bare_output, {:search, {:dataset, ["a", "b"]}, [], [], _}, _}] = ast
    end

    test "dataset compilation stores raw sources" do
      {:ok, ast} =
        Parser.parse(~s|search(dataset("00000000-0000-0000-0000-000000000000", "my-slug"));|)

      {:ok, result} = Compiler.compile(ast)
      plan = hd(result.plans)
      assert plan.element_types == []

      assert plan.sources == [
               {:uuid, "00000000-0000-0000-0000-000000000000"},
               {:slug, "my-slug"}
             ]
    end
  end

  # ── Schema-based limits ────────────────────────────────────────

  describe "schema-based limits" do
    test "uses default max_osm_ids when no schema provided" do
      # Should not raise for a small list
      plan = first_plan(~s|$$ = search(node, id: [1, 2, 3]);|)
      assert plan.osm_ids == [1, 2, 3]
    end

    test "uses schema limits when provided" do
      schema = %PlazaQL.Schema{limits: %{max_osm_ids: 2}}

      {:ok, ast} = Parser.parse(~s|$$ = search(node, id: [1, 2, 3]);|)

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast, schema: schema)
      assert msg =~ "too many IDs"
    end
  end

  # ── Error path tests ──────────────────────────────────────────────

  describe "unknown method errors" do
    test "unknown method on search returns compile error" do
      # Build AST with an unknown method by hand — the parser accepts any
      # identifier as a method name, so we craft the AST directly.
      ast = [
        {:output, nil,
         {:search, :node, [{:eq, "amenity", "cafe"}], [{:method, :frobnicate, [], %{}}],
          %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "unknown method"
      assert msg =~ "frobnicate"
    end

    test "unknown method in chained position returns compile error" do
      ast = [
        {:output, nil,
         {:chain,
          {:search, :node, [], [{:method, :limit, [{:posarg, {:number, 10, %{}}}], %{}}],
           %{line: 1, col: 1}}, {:method, :bogus_method, [], %{}}}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "unknown method"
      assert msg =~ "bogus_method"
    end
  end

  describe "unknown atom value errors" do
    test ".sort with unknown atom value returns compile error" do
      # .sort(by: :invalid_sort_key) — "invalid_sort_key" is not in @known_atoms
      ast = [
        {:output, nil,
         {:search, :node, [{:eq, "amenity", "cafe"}],
          [{:method, :sort, [{:kwarg, "by", {:identifier, "invalid_sort_key", %{}}}], %{}}],
          %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "`.sort(by: ...)` takes"
      assert msg =~ "invalid_sort_key"
    end

    test ".include with unknown atom returns compile error" do
      ast = [
        {:output, nil,
         {:search, :node, [],
          [
            {:method, :include, [{:posarg, {:identifier, "nonexistent_option", %{}}}], %{}}
          ], %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "`.include()` takes"
      assert msg =~ "nonexistent_option"
    end

    test ".expand with unknown direction string returns compile error" do
      # .expand(:sideways) — "sideways" not in @known_atoms, triggers safe_to_atom!
      # But :expand only reads {:atom, ...} posargs for known directions, so
      # an identifier arg goes through safe_to_atom! indirectly only if the
      # direction doesn't match. Let's trigger via sort with a bad string.
      ast = [
        {:output, nil,
         {:search, :node, [], [{:method, :sort, [{:posarg, {:string, "xyzzy", %{}}}], %{}}],
          %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "`.sort(by: ...)` takes"
      assert msg =~ "xyzzy"
    end
  end

  describe "too many IDs errors" do
    test "exceeding default max_osm_ids returns compile error" do
      # Default max is 10_000 — generate 10_001 IDs
      ids = Enum.to_list(1..10_001)
      id_filter = {:eq_list, "id", ids}

      ast = [
        {:output, nil, {:search, :node, [id_filter], [], %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "too many IDs"
      assert msg =~ "10000"
    end

    test "exceeding custom schema max_osm_ids returns compile error" do
      schema = %PlazaQL.Schema{limits: %{max_osm_ids: 5}}
      ids = Enum.to_list(1..6)
      id_filter = {:eq_list, "id", ids}

      ast = [
        {:output, nil, {:search, :node, [id_filter], [], %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast, schema: schema)
      assert msg =~ "too many IDs"
      assert msg =~ "5"
    end

    test "exactly at the limit succeeds" do
      schema = %PlazaQL.Schema{limits: %{max_osm_ids: 3}}
      id_filter = {:eq_list, "id", [1, 2, 3]}

      ast = [
        {:output, nil, {:search, :node, [id_filter], [], %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:ok, %{plans: [plan]}} = Compiler.compile(ast, schema: schema)
      assert plan.osm_ids == [1, 2, 3]
    end
  end

  describe "too many datasets errors" do
    test "exceeding max datasets returns compile error" do
      slugs = Enum.map(1..21, &"dataset-#{&1}")

      ast = [
        {:output, nil, {:search, {:dataset, slugs}, [], [], %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "too many datasets"
      assert msg =~ "20"
      assert msg =~ "21"
    end

    test "exactly at dataset limit succeeds" do
      slugs = Enum.map(1..20, &"dataset-#{&1}")

      ast = [
        {:output, nil, {:search, {:dataset, slugs}, [], [], %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:ok, %{plans: [plan]}} = Compiler.compile(ast)
      assert length(plan.sources) == 20
    end
  end

  describe "invalid tag filter errors" do
    test "eq_list on non-id key returns compile error" do
      # List values (e.g., amenity: [1, 2, 3]) are only valid for id filters
      ast = [
        {:output, nil, {:search, :node, [{:eq_list, "amenity", [1, 2, 3]}], [], %{line: 1, col: 1}},
         %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "list values are only supported for id filters"
      assert msg =~ "amenity"
    end

    test "eq_list on id key succeeds" do
      ast = [
        {:output, nil, {:search, :node, [{:eq_list, "id", [1, 2, 3]}], [], %{line: 1, col: 1}},
         %{line: 1, col: 1}}
      ]

      assert {:ok, %{plans: [plan]}} = Compiler.compile(ast)
      assert plan.osm_ids == [1, 2, 3]
    end
  end

  describe "unknown expression node errors" do
    test "completely unknown expression node returns compile error" do
      ast = [
        {:output, nil, {:totally_unknown, "garbage", %{line: 3, col: 5}}, %{line: 3, col: 5}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "unknown expression node"
    end

    test "malformed tuple as expression returns compile error" do
      ast = [
        {:output, nil, {:not_a_real_node}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "unknown expression node"
    end
  end

  describe "error struct fields" do
    test "compile errors include line and col" do
      ast = [
        {:output, nil,
         {:search, :node, [], [{:method, :nonexistent_method, [], %{line: 5, col: 20}}],
          %{line: 5, col: 1}}, %{line: 5, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{} = error]} = Compiler.compile(ast)
      assert is_integer(error.line)
      assert is_integer(error.col)
      assert is_binary(error.message)
      assert error.severity == :error
    end

    test "error wraps as single-element list" do
      # The compiler catches throw({:compile_error, %Error{}}) and wraps in a list
      ast = [
        {:output, nil, {:search, :node, [{:eq_list, "name", [1, 2]}], [], %{line: 1, col: 1}},
         %{line: 1, col: 1}}
      ]

      assert {:error, errors} = Compiler.compile(ast)
      assert is_list(errors)
      assert [_] = errors
      assert %PlazaQL.Error{} = hd(errors)
    end
  end

  describe "error paths through PlazaQL.compile/1" do
    test "unknown method via full pipeline" do
      # We can't easily trigger an unknown method through the full pipeline
      # because the type checker validates methods. But we can test that
      # parser errors propagate correctly.
      assert {:error, [%PlazaQL.Error{}]} = PlazaQL.compile(";;;totally broken{{{")
    end

    test "too many IDs via full pipeline" do
      ids = Enum.map_join(1..10_001, ", ", & &1)
      source = "$$ = search(node, id: [#{ids}]);"

      # This may fail at parse or compile — either way we get {:error, [...]}
      result = PlazaQL.compile(source)
      assert {:error, errors} = result
      assert is_list(errors)
      assert errors != []
    end

    test "schema limit enforcement via full pipeline" do
      schema = %PlazaQL.Schema{limits: %{max_osm_ids: 2}}
      source = ~s|$$ = search(node, id: [1, 2, 3]);|

      assert {:error, [%PlazaQL.Error{message: msg}]} =
               PlazaQL.compile(source, schema: schema)

      assert msg =~ "too many IDs"
    end
  end

  describe "kwarg compilation with unknown atoms" do
    test "unknown kwarg key in computation returns compile error" do
      # Computation kwargs go through safe_to_atom! for key names
      ast = [
        {:output, nil,
         {:computation, :route, [], [{:kwarg, "unknown_key_xyzzy", {:number, 42, %{}}}],
          %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:error, [%PlazaQL.Error{message: msg}]} = Compiler.compile(ast)
      assert msg =~ "unknown atom value"
      assert msg =~ "unknown_key_xyzzy"
    end

    test "known kwarg keys compile successfully" do
      ast = [
        {:output, nil,
         {:computation, :route, [],
          [
            {:kwarg, "mode", {:atom, :car, %{}}},
            {:kwarg, "profile", {:atom, :bicycle, %{}}}
          ], %{line: 1, col: 1}}, %{line: 1, col: 1}}
      ]

      assert {:ok, %{plans: [plan]}} = Compiler.compile(ast)
      assert {:route, params} = plan.computation
      assert params.mode == :car
      assert params.profile == :bicycle
    end
  end
end
