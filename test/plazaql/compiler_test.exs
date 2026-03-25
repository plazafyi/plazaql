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
end
