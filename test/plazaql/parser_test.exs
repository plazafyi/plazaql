defmodule PlazaQL.ParserTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Parser

  defp parse!(source) do
    case Parser.parse(source) do
      {:ok, ast} -> ast
      {:error, errors} -> flunk("Parse failed: #{inspect(errors)}")
    end
  end

  defp parse_expr!(source) do
    # Wrap expression in output assignment to parse as statement
    [node] = parse!("$$ = #{source};")
    {:output, nil, expr, _pos} = node
    expr
  end

  # ── Variable assignment ────────────────────────────────────────────

  describe "variable assignment" do
    test "geometry variable" do
      [{:var_assign, "$p", {:point, 38.9, -77.0, _}, meta}] =
        parse!("$p = point(38.9, -77.0);")

      assert meta.line == 1
    end

    test "search variable" do
      [{:var_assign, "$cafes", {:search, :node, _, [], _}, _meta}] =
        parse!("$cafes = search(node, amenity: \"cafe\");")
    end

    test "computation variable" do
      [{:var_assign, "$r", {:computation, :route, _, _, _}, _meta}] =
        parse!(
          "$r = route(origin: point(38.9, -77.0), destination: point(40.7, -74.0), mode: \"auto\");"
        )
    end
  end

  # ── Output ─────────────────────────────────────────────────────────

  describe "output" do
    test "default output" do
      [{:output, nil, {:search, :node, _, [], _}, meta}] =
        parse!("$$ = search(node, amenity: \"cafe\");")

      assert meta.line == 1
    end

    test "named output" do
      [{:output, "cafes", {:search, nil, _, [], _}, _meta}] =
        parse!("$$.cafes = search(amenity: \"cafe\");")
    end

    test "bare expression as implicit output" do
      [{:bare_output, {:search, :node, _, [], _}, meta}] =
        parse!("search(node, amenity: \"cafe\");")

      assert meta.line == 1
    end

    test "bare expression with method chain" do
      [{:bare_output, {:search, :node, _, [_limit], _}, _meta}] =
        parse!("search(node, amenity: \"cafe\").limit(10);")
    end

    test "bare computation" do
      [{:bare_output, {:computation, :route, _, _, _}, _meta}] =
        parse!("route(point(38.9, -77.0), point(40.7, -74.0));")
    end

    test "bare variable reference" do
      [{:var_assign, "$cafes", _, _}, {:bare_output, {:var_ref, "$cafes", _}, _}] =
        parse!("$cafes = search(node, amenity: \"cafe\");\n$cafes;")
    end

    test "bare set operation" do
      [{:bare_output, {:union, _, _, _}, _}] =
        parse!(~s|search(amenity: "cafe") + search(amenity: "bar");|)
    end
  end

  # ── Search ─────────────────────────────────────────────────────────

  describe "search" do
    test "no type, single filter" do
      expr = parse_expr!("search(amenity: \"cafe\")")
      assert {:search, nil, [{:eq, "amenity", "cafe"}], [], _meta} = expr
    end

    test "with type" do
      expr = parse_expr!("search(node, amenity: \"cafe\")")
      assert {:search, :node, [{:eq, "amenity", "cafe"}], [], _meta} = expr
    end

    test "nwr type with regex" do
      expr = parse_expr!("search(nwr, name: ~\"Starbucks\")")
      assert {:search, :nwr, [{:regex, "name", "Starbucks"}], [], _} = expr
    end

    test "exists + neq filters" do
      expr = parse_expr!("search(amenity: *, cuisine: !\"fast_food\")")
      assert {:search, nil, filters, [], _} = expr
      assert [{:exists, "amenity"}, {:neq, "cuisine", "fast_food"}] = filters
    end

    test "case-insensitive regex" do
      expr = parse_expr!("search(name: ~i\"café\")")
      assert {:search, nil, [{:regex_i, "name", "café"}], [], _} = expr
    end

    test "not exists" do
      expr = parse_expr!("search(amenity: !*)")
      assert {:search, nil, [{:not_exists, "amenity"}], [], _} = expr
    end

    test "negated regex" do
      expr = parse_expr!("search(name: !~\"test\")")
      assert {:search, nil, [{:not_regex, "name", "test"}], [], _} = expr
    end

    test "empty search" do
      expr = parse_expr!("search()")
      assert {:search, nil, [], [], _} = expr
    end

    test "type only, no filters" do
      expr = parse_expr!("search(way)")
      assert {:search, :way, [], [], _} = expr
    end
  end

  # ── Dataset source ────────────────────────────────────────────────

  describe "dataset source" do
    test "single dataset slug" do
      expr = parse_expr!(~s|search(dataset("my-data"))|)
      assert {:search, {:dataset, ["my-data"]}, [], [], _} = expr
    end

    test "multiple dataset slugs" do
      expr = parse_expr!(~s|search(dataset("ds1", "ds2", "ds3"))|)
      assert {:search, {:dataset, ["ds1", "ds2", "ds3"]}, [], [], _} = expr
    end

    test "dataset with tag filters" do
      expr = parse_expr!(~s|search(dataset("my-data"), amenity: "cafe")|)
      assert {:search, {:dataset, ["my-data"]}, [{:eq, "amenity", "cafe"}], [], _} = expr
    end

    test "dataset with multiple filters" do
      expr = parse_expr!(~s|search(dataset("my-data"), category: "park", name: ~"Central")|)
      assert {:search, {:dataset, ["my-data"]}, filters, [], _} = expr
      assert [{:eq, "category", "park"}, {:regex, "name", "Central"}] = filters
    end

    test "dataset with method chain" do
      [node] = parse!(~s|search(dataset("my-data")).limit(10);|)
      assert {:bare_output, {:search, {:dataset, ["my-data"]}, [], [_method], _pos}, _} = node
    end
  end

  # ── Boundary ─────────────────────────────────────────────────────

  describe "boundary" do
    test "basic boundary with filters" do
      expr = parse_expr!(~s|boundary(name: "Berlin", admin_level: "4")|)
      assert {:boundary, filters, _} = expr
      assert [{:eq, "name", "Berlin"}, {:eq, "admin_level", "4"}] = filters
    end

    test "boundary with regex" do
      expr = parse_expr!("boundary(name: ~\"New York\")")
      assert {:boundary, [{:regex, "name", "New York"}], _} = expr
    end
  end

  # ── Geometry constructors ──────────────────────────────────────────

  describe "geometry constructors" do
    test "point positional" do
      expr = parse_expr!("point(38.9, -77.0)")
      assert {:point, 38.9, -77.0, meta} = expr
      assert meta.line == 1
    end

    test "point keyword" do
      expr = parse_expr!("point(lat: 38.9, lng: -77.0)")
      assert {:point, 38.9, -77.0, _meta} = expr
    end

    test "linestring" do
      expr = parse_expr!("linestring(point(38.9, -77.0), point(40.7, -74.0))")
      assert {:linestring, [p1, p2], _meta} = expr
      assert {:point, 38.9, -77.0, _} = p1
      assert {:point, 40.7, -74.0, _} = p2
    end

    test "polygon" do
      expr =
        parse_expr!("polygon(point(38.9, -77.0), point(40.7, -74.0), point(39.0, -75.0))")

      assert {:polygon, [_, _, _], _meta} = expr
    end

    test "bbox" do
      expr = parse_expr!("bbox(40.7, -74.0, 40.8, -73.9)")
      assert {:bbox, 40.7, -74.0, 40.8, -73.9, _meta} = expr
    end
  end

  # ── Method chains ──────────────────────────────────────────────────

  describe "method chains" do
    test "around with keyword args" do
      expr =
        parse_expr!(
          "search(node, amenity: \"cafe\").around(distance: 500, geometry: point(38.9, -77.0))"
        )

      assert {:search, :node, _, methods, _} = expr

      assert [
               {:method, :around,
                [
                  {:kwarg, "distance", {:number, 500, _}},
                  {:kwarg, "geometry", {:point, 38.9, -77.0, _}}
                ], _}
             ] = methods
    end

    test "around with positional args" do
      expr = parse_expr!("search(node, amenity: \"cafe\").around(500, point(38.9, -77.0))")

      assert {:search, :node, _, [method], _} = expr

      assert {:method, :around, [{:posarg, {:number, 500, _}}, {:posarg, {:point, _, _, _}}], _} =
               method
    end

    test "within with variable" do
      expr = parse_expr!("search(amenity: \"cafe\").within(geometry: $berlin)")

      assert {:search, nil, _, [method], _} = expr
      assert {:method, :within, [{:kwarg, "geometry", {:var_ref, "$berlin", _}}], _} = method
    end

    test "intersects" do
      expr = parse_expr!("search(amenity: \"cafe\").intersects(geometry: $region)")
      assert {:search, nil, _, [{:method, :intersects, _, _}], _} = expr
    end

    test "bbox method" do
      expr = parse_expr!("search(amenity: \"cafe\").bbox(40.7, -74.0, 40.8, -73.9)")
      assert {:search, nil, _, [{:method, :bbox, _, _}], _} = expr
    end

    test "buffer" do
      expr = parse_expr!("search(amenity: \"cafe\").buffer(meters: 50)")

      assert {:search, nil, _, [{:method, :buffer, [{:kwarg, "meters", {:number, 50, _}}], _}], _} =
               expr
    end

    test "sort" do
      expr = parse_expr!("search(amenity: \"cafe\").sort(by: :distance)")

      assert {:search, nil, _, [{:method, :sort, _, _}], _} = expr
    end

    test "limit + offset chained" do
      expr = parse_expr!("search(amenity: \"cafe\").limit(20).offset(40)")

      assert {:search, nil, _, [limit_m, offset_m], _} = expr
      assert {:method, :limit, [{:posarg, {:number, 20, _}}], _} = limit_m
      assert {:method, :offset, [{:posarg, {:number, 40, _}}], _} = offset_m
    end

    test "no-arg output mode methods" do
      expr = parse_expr!("search(amenity: \"cafe\").count")
      assert {:search, nil, _, [{:method, :count, [], _}], _} = expr
    end

    test "chained no-arg methods" do
      expr = parse_expr!("search(amenity: \"cafe\").ids")
      assert {:search, nil, _, [{:method, :ids, [], _}], _} = expr
    end

    test "full chain with multiple phases" do
      expr =
        parse_expr!(
          "search(node, amenity: \"cafe\").around(500, point(38.9, -77.0)).buffer(meters: 50).sort(by: :distance).limit(10)"
        )

      assert {:search, :node, _, methods, _} = expr
      assert length(methods) == 4
      assert {:method, :around, _, _} = Enum.at(methods, 0)
      assert {:method, :buffer, _, _} = Enum.at(methods, 1)
      assert {:method, :sort, _, _} = Enum.at(methods, 2)
      assert {:method, :limit, _, _} = Enum.at(methods, 3)
    end
  end

  # ── Filter method ──────────────────────────────────────────────────

  describe "filter method" do
    test "filter with tag filters after search" do
      expr =
        parse_expr!(~s|search(amenity: "cafe").filter(wheelchair: "yes", cuisine: ~"italian")|)

      assert {:search, nil, _, [filter_method], _} = expr

      assert {:method, :filter, [{:eq, "wheelchair", "yes"}, {:regex, "cuisine", "italian"}], _} =
               filter_method
    end
  end

  # ── Set operations ─────────────────────────────────────────────────

  describe "set operations" do
    test "union" do
      expr = parse_expr!(~s|search(amenity: "cafe") + search(amenity: "restaurant")|)
      assert {:union, {:search, nil, _, [], _}, {:search, nil, _, [], _}, _} = expr
    end

    test "difference" do
      expr = parse_expr!(~s|search(amenity: "cafe") - search(name: "Starbucks")|)
      assert {:difference, {:search, _, _, _, _}, {:search, _, _, _, _}, _} = expr
    end

    test "chained set operations with parens" do
      expr =
        parse_expr!(~s|(search(amenity: "cafe") + search(amenity: "bar")) - search(name: "Closed")|)

      assert {:difference, {:union, _, _, _}, {:search, _, _, _, _}, _} = expr
    end
  end

  # ── Computation functions ──────────────────────────────────────────

  describe "computation functions" do
    test "route with keyword args" do
      expr =
        parse_expr!(
          "route(origin: point(38.9, -77.0), destination: point(40.7, -74.0), mode: \"auto\")"
        )

      assert {:computation, :route, [], opts, _} = expr
      assert length(opts) == 3
    end

    test "isochrone" do
      expr = parse_expr!("isochrone(center: point(38.9, -77.0), time: 600, mode: \"foot\")")
      assert {:computation, :isochrone, [], opts, _} = expr
      assert length(opts) == 3
    end

    test "geocode" do
      expr = parse_expr!("geocode(query: \"coffee\", limit: 5)")
      assert {:computation, :geocode, [], opts, _} = expr
      assert [{:kwarg, "query", {:string, "coffee", _}}, {:kwarg, "limit", {:number, 5, _}}] = opts
    end

    test "nearest" do
      expr = parse_expr!("nearest(point: point(38.9, -77.0), radius: 1000)")
      assert {:computation, :nearest, [], opts, _} = expr
      assert length(opts) == 2
    end

    test "matrix with lists" do
      expr =
        parse_expr!(
          "matrix(origins: [point(38.9, -77.0), point(40.7, -74.0)], destinations: [point(39.0, -75.0)], mode: \"foot\")"
        )

      assert {:computation, :matrix, [], opts, _} = expr
      assert length(opts) == 3
    end
  end

  # ── Variable references ────────────────────────────────────────────

  describe "variable references" do
    test "variable in method args" do
      expr = parse_expr!("search(amenity: \"cafe\").within(geometry: $berlin)")

      assert {:search, nil, _,
              [{:method, :within, [{:kwarg, "geometry", {:var_ref, "$berlin", _}}], _}], _} = expr
    end

    test "variable as expression" do
      [{:output, nil, {:var_ref, "$cafes", meta}, _}] = parse!("$$ = $cafes;")
      assert meta.line == 1
    end

    test "output variable reference in method args" do
      ast =
        parse!("""
        $$.route = route(origin: point(38.9, -77.0), destination: point(40.7, -74.0));
        $$.stops = search(amenity: "cafe").around(200, $$.route);
        """)

      assert [
               {:output, "route", _, _},
               {:output, "stops",
                {:search, nil, _,
                 [
                   {:method, :around,
                    [{:posarg, {:number, 200, _}}, {:posarg, {:output_var_ref, "route", _}}], _}
                 ], _}, _}
             ] = ast
    end

    test "output variable reference as expression" do
      ast =
        parse!("""
        $$.area = boundary(name: "Berlin");
        $$.cafes = $$.area;
        """)

      assert [
               {:output, "area", {:boundary, _, _}, _},
               {:output, "cafes", {:output_var_ref, "area", _}, _}
             ] = ast
    end

    test "output variable reference not confused with assignment" do
      # $$.name followed by = is assignment, not reference
      [{:output, "x", {:number, 1, _}, _}] = parse!("$$.x = 1;")
    end

    test "variables in linestring constructor" do
      [
        {:var_assign, "$a", {:point, _, _, _}, _},
        {:var_assign, "$b", {:point, _, _, _}, _},
        {:var_assign, "$line", {:linestring, items, _}, _}
      ] =
        parse!("""
        $a = point(38.9, -77.0);
        $b = point(40.7, -74.0);
        $line = linestring($a, $b);
        """)

      assert [{:var_ref, "$a", _}, {:var_ref, "$b", _}] = items
    end
  end

  # ── Comments ───────────────────────────────────────────────────────

  describe "comments" do
    test "line comment" do
      ast = parse!("// this is a comment\n$$ = search(amenity: \"cafe\");")
      assert [{:output, nil, {:search, _, _, _, _}, _}] = ast
    end

    test "block comment" do
      ast = parse!("/* block comment */\n$$ = search(amenity: \"cafe\");")
      assert [{:output, nil, {:search, _, _, _, _}, _}] = ast
    end

    test "inline comment between statements" do
      ast =
        parse!("""
        $a = point(38.9, -77.0); // point A
        /* search nearby */
        $$ = search(amenity: "cafe");
        """)

      assert length(ast) == 2
    end
  end

  # ── Complex queries ────────────────────────────────────────────────

  describe "complex queries" do
    test "multi-statement with variable, search, chain, output" do
      ast =
        parse!("""
        $berlin = boundary(name: "Berlin", admin_level: "4");
        $cafes = search(node, amenity: "cafe").within(geometry: $berlin).limit(50);
        $$ = $cafes;
        """)

      assert [
               {:var_assign, "$berlin", {:boundary, _, _}, _},
               {:var_assign, "$cafes", {:search, :node, _, methods, _}, _},
               {:output, nil, {:var_ref, "$cafes", _}, _}
             ] = ast

      assert length(methods) == 2
    end

    test "union of searches with method chain" do
      ast =
        parse!("""
        $$ = (search(amenity: "cafe") + search(amenity: "restaurant")).around(500, point(38.9, -77.0)).limit(20);
        """)

      assert [
               {:output, nil,
                {:chain, {:chain, {:union, _, _, _}, {:method, :around, _, _}},
                 {:method, :limit, _, _}}, _}
             ] = ast
    end
  end

  # ── Literals ───────────────────────────────────────────────────────

  describe "literals" do
    test "integer" do
      expr = parse_expr!("500")
      assert {:number, 500, _} = expr
    end

    test "float" do
      expr = parse_expr!("38.9")
      assert {:number, 38.9, _} = expr
    end

    test "negative number" do
      expr = parse_expr!("-77.0")
      assert {:number, -77.0, _} = expr
    end

    test "string" do
      expr = parse_expr!("\"hello world\"")
      assert {:string, "hello world", _} = expr
    end

    test "boolean true" do
      expr = parse_expr!("true")
      assert {:bool, true, _} = expr
    end

    test "boolean false" do
      expr = parse_expr!("false")
      assert {:bool, false, _} = expr
    end

    test "atom" do
      expr = parse_expr!(":down")
      assert {:atom, :down, _} = expr
    end
  end

  # ── Source positions ───────────────────────────────────────────────

  describe "source positions" do
    test "search position on line 2" do
      ast =
        parse!("""
        $x = point(38.9, -77.0);
        $$ = search(amenity: "cafe");
        """)

      [{:var_assign, _, _, _}, {:output, nil, {:search, _, _, _, search_meta}, out_meta}] = ast
      assert out_meta.line == 2
      assert search_meta.line == 2
    end

    test "point position" do
      expr = parse_expr!("point(38.9, -77.0)")
      {:point, _, _, meta} = expr
      # "$$ = " is 5 chars, so point starts at col 6
      assert meta.col == 6
    end
  end

  # ── Error cases ────────────────────────────────────────────────────

  describe "error cases" do
    test "missing semicolon" do
      assert {:error, [%PlazaQL.Error{line: _, col: _}]} =
               Parser.parse("$$ = search(amenity: \"cafe\")")
    end

    test "unclosed string" do
      assert {:error, [%PlazaQL.Error{}]} =
               Parser.parse("$$ = search(amenity: \"cafe);")
    end

    test "invalid syntax" do
      assert {:error, [%PlazaQL.Error{}]} =
               Parser.parse("@@@ invalid")
    end
  end

  # ── Expand / recursion ─────────────────────────────────────────────

  describe "expand method" do
    test "expand with atom arg" do
      expr = parse_expr!("search(way, highway: \"residential\").expand(:down)")
      assert {:search, :way, _, [{:method, :expand, [{:posarg, {:atom, :down, _}}], _}], _} = expr
    end
  end

  # ── Bracket references ──────────────────────────────────────────

  describe "bracket references" do
    test "$var[attr] parses as bracket_ref" do
      expr = parse_expr!("$stop[route_id]")
      assert {:bracket_ref, "$stop", "route_id", _pos} = expr
    end

    test "$$.name[attr] parses as bracket_ref with output var" do
      expr = parse_expr!("$$.routes[ref]")
      assert {:bracket_ref, "$$.routes", "ref", _pos} = expr
    end

    test "$var[quoted_attr] with quoted string" do
      expr = parse_expr!("$stop[\"addr:street\"]")
      assert {:bracket_ref, "$stop", "addr:street", _pos} = expr
    end

    test "$var without brackets still parses as var_ref" do
      expr = parse_expr!("$stop")
      assert {:var_ref, "$stop", _pos} = expr
    end

    test "bracket ref as tag filter value in search" do
      expr = parse_expr!("search(node, route_id: $stop[route_id])")

      assert {:search, :node,
              [{:bracket_ref_eq, "route_id", {:bracket_ref, "$stop", "route_id", _}}], [], _} =
               expr
    end

    test "output bracket ref as tag filter value" do
      expr = parse_expr!("search(node, ref: $$.routes[ref])")

      assert {:search, :node, [{:bracket_ref_eq, "ref", {:bracket_ref, "$$.routes", "ref", _}}], [],
              _} = expr
    end
  end

  # ── Join methods ────────────────────────────────────────────────

  describe "join methods" do
    test "member_of with var ref" do
      expr = parse_expr!("search(node).member_of($route)")

      assert {:search, :node, [], [{:method, :member_of, [{:posarg, {:var_ref, "$route", _}}], _}],
              _} = expr
    end

    test "has_member with var ref" do
      expr = parse_expr!("search(relation).has_member($stops)")

      assert {:search, :relation, [],
              [{:method, :has_member, [{:posarg, {:var_ref, "$stops", _}}], _}], _} = expr
    end

    test "member_of with inline search expression" do
      expr =
        parse_expr!(~s[search(node, highway: "bus_stop").member_of(search(relation, route: "bus"))])

      assert {:search, :node, _,
              [{:method, :member_of, [{:posarg, {:search, :relation, _, [], _}}], _}], _} = expr
    end

    test "member_of with role kwarg" do
      expr = parse_expr!("search(node).member_of($route, role: \"stop\")")

      assert {:search, :node, [],
              [
                {:method, :member_of,
                 [{:posarg, {:var_ref, "$route", _}}, {:kwarg, "role", {:string, "stop", _}}], _}
              ], _} = expr
    end
  end

  # ── Narrowing methods ──────────────────────────────────────────

  describe "narrowing methods" do
    test "first" do
      expr = parse_expr!("search(node, amenity: \"cafe\").first()")
      assert {:search, :node, _, [{:method, :first, [], _}], _} = expr
    end

    test "last" do
      expr = parse_expr!("search(node, amenity: \"cafe\").last()")
      assert {:search, :node, _, [{:method, :last, [], _}], _} = expr
    end

    test "index with integer arg" do
      expr = parse_expr!("search(node, amenity: \"cafe\").index(3)")

      assert {:search, :node, _, [{:method, :index, [{:posarg, {:number, 3, _}}], _}], _} = expr
    end
  end

  # ── .sort() expression parsing ────────────────────────────────

  describe ".sort() expression parsing" do
    test "positional tag access: .sort(t[\"name\"])" do
      expr = parse_expr!("search(node).sort(t[\"name\"])")

      assert {:search, :node, [], [{:method, :sort_expr, {:tag_access, "name", _}, :asc, _}], _} =
               expr
    end

    test "positional with order: .sort(t[\"name\"], order: :desc)" do
      expr = parse_expr!("search(node).sort(t[\"name\"], order: :desc)")

      assert {:search, :node, [], [{:method, :sort_expr, {:tag_access, "name", _}, :desc, _}], _} =
               expr
    end

    test "keyword form: .sort(by: t[\"name\"])" do
      expr = parse_expr!("search(node).sort(by: t[\"name\"])")

      assert {:search, :node, [], [{:method, :sort_expr, {:tag_access, "name", _}, :asc, _}], _} =
               expr
    end

    test "keyword with order: .sort(by: t[\"name\"], order: :desc)" do
      expr = parse_expr!("search(node).sort(by: t[\"name\"], order: :desc)")

      assert {:search, :node, [], [{:method, :sort_expr, {:tag_access, "name", _}, :desc, _}], _} =
               expr
    end

    test "distance function: .sort(distance(point(48.85, 2.35)))" do
      expr = parse_expr!("search(node).sort(distance(point(48.85, 2.35)))")

      assert {:search, :node, [],
              [{:method, :sort_expr, {:geom_func, :distance, {48.85, 2.35}, _}, :asc, _}], _} = expr
    end

    test "area function: .sort(area())" do
      expr = parse_expr!("search(node).sort(area())")

      assert {:search, :node, [], [{:method, :sort_expr, {:geom_func, :area, _}, :asc, _}], _} =
               expr
    end

    test "length function: .sort(length())" do
      expr = parse_expr!("search(node).sort(length())")

      assert {:search, :node, [], [{:method, :sort_expr, {:geom_func, :length, _}, :asc, _}], _} =
               expr
    end

    test "elevation function: .sort(elevation())" do
      expr = parse_expr!("search(node).sort(elevation())")

      assert {:search, :node, [], [{:method, :sort_expr, {:geom_func, :elevation, _}, :asc, _}], _} =
               expr
    end

    test "numeric coercion: .sort(number(t[\"population\"]))" do
      expr = parse_expr!("search(node).sort(number(t[\"population\"]))")

      assert {:search, :node, [],
              [
                {:method, :sort_expr, {:coerce_func, :number, {:tag_access, "population", _}, _},
                 :asc, _}
              ], _} = expr
    end

    test "default order is :asc when omitted" do
      expr = parse_expr!("search(node).sort(t[\"name\"])")
      assert {:search, :node, [], [{:method, :sort_expr, _, :asc, _}], _} = expr

      expr_kw = parse_expr!("search(node).sort(by: t[\"name\"])")
      assert {:search, :node, [], [{:method, :sort_expr, _, :asc, _}], _} = expr_kw
    end
  end

  # ── Plan 1: Core gaps ──────────────────────────────────────────

  describe "ID filter" do
    test "numeric ID" do
      expr = parse_expr!("search(node, id: 12345)")
      assert {:search, :node, [{:eq_num, "id", 12_345}], [], _} = expr
    end

    test "ID list" do
      expr = parse_expr!("search(node, id: [1, 2, 3])")
      assert {:search, :node, [{:eq_list, "id", [1, 2, 3]}], [], _} = expr
    end
  end

  describe "key+value regex filter" do
    test "key regex with value regex" do
      expr = parse_expr!(~s|search(node, ~"^addr:": ~"^[0-9]")|)
      assert {:search, :node, [{:key_value_regex, "^addr:", "^[0-9]"}], [], _} = expr
    end

    test "key regex with wildcard" do
      expr = parse_expr!(~s|search(node, ~"^name:": *)|)
      assert {:search, :node, [{:key_regex_exists, "^name:"}], [], _} = expr
    end
  end

  describe "set intersection" do
    test "parses & operator" do
      ast =
        parse!("""
        $cafes = search(node, amenity: "cafe");
        $italian = search(node, cuisine: "italian");
        $$ = $cafes & $italian;
        """)

      assert [{:var_assign, _, _, _}, {:var_assign, _, _, _}, {:output, nil, expr, _}] = ast
      assert {:intersection, {:var_ref, _, _}, {:var_ref, _, _}, _} = expr
    end
  end

  describe "global directive" do
    test "parses #bbox directive" do
      ast =
        parse!("""
        #bbox(47, 10, 48, 11);
        $$ = search(node, amenity: "cafe");
        """)

      assert [{:directive, :bbox, args, _}, {:output, nil, _, _}] = ast

      assert [
               {:posarg, {:number, 47, _}},
               {:posarg, {:number, 10, _}},
               {:posarg, {:number, 48, _}},
               {:posarg, {:number, 11, _}}
             ] = args
    end

    test "parses #within directive" do
      ast =
        parse!("""
        #within(boundary(name: "Berlin"));
        search(node, amenity: "cafe");
        """)

      assert [{:directive, :within, [{:posarg, {:boundary, _, _}}], _}, {:bare_output, _, _}] = ast
    end

    test "parses #filter tag directive" do
      ast =
        parse!("""
        #filter(amenity: *);
        search(node);
        """)

      assert [{:directive, :filter, [{:exists, "amenity"}], _}, {:bare_output, _, _}] = ast
    end

    test "parses #filter expression directive" do
      ast =
        parse!("""
        #filter(t["population"] > 1000);
        search(node);
        """)

      assert [{:directive, :filter_expr, {:bin_op, :gt, _, _, _}, _}, {:bare_output, _, _}] = ast
    end

    test "parses #limit directive" do
      ast =
        parse!("""
        #limit(10);
        search(node, amenity: "cafe");
        """)

      assert [{:directive, :limit, [{:posarg, {:number, 10, _}}], _}, {:bare_output, _, _}] = ast
    end

    test "parses multiple directives" do
      ast =
        parse!("""
        #bbox(47, 10, 48, 11);
        #limit(100);
        search(node, amenity: "cafe");
        """)

      assert [
               {:directive, :bbox, _, _},
               {:directive, :limit, _, _},
               {:bare_output, _, _}
             ] = ast
    end
  end

  describe "geom method" do
    test "parses .geom()" do
      expr = parse_expr!("search(node, amenity: \"cafe\").geom()")
      assert {:search, :node, _, [{:method, :geom, [], _}], _} = expr
    end
  end

  describe "qt sort" do
    test "parses .sort(by: :qt)" do
      expr = parse_expr!("search(node, amenity: \"cafe\").sort(by: :qt)")
      assert {:search, :node, _, [{:method, :sort, [{:kwarg, "by", {:atom, :qt, _}}], _}], _} = expr
    end
  end

  # ── Expression language ──────────────────────────────────────────

  describe "expression filter" do
    test "tag access" do
      expr = parse_expr!(~s|search(node, amenity: "cafe").filter(t["capacity"] == "50")|)

      assert {:search, :node, _filters,
              [
                {:method, :filter_expr,
                 {:bin_op, :eq, {:tag_access, "capacity", _}, {:string, "50", _}, _}, _}
              ], _} = expr
    end

    test "property accessors" do
      expr = parse_expr!("search(node).filter(id() > 1000)")

      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :gt, {:prop_access, :id, _}, {:number, 1000, _}, _}, _}
              ], _} = expr
    end

    test "lat/lon accessors" do
      expr = parse_expr!("search(node).filter(lat() > 40.0)")

      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :gt, {:prop_access, :lat, _}, {:number, 40.0, _}, _}, _}
              ], _} = expr
    end

    test "geometry function: length" do
      expr = parse_expr!("search(way).filter(length() > 5000)")

      assert {:search, :way, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :gt, {:geom_func, :length, _}, {:number, 5000, _}, _}, _}
              ], _} = expr
    end

    test "geometry function: area" do
      expr = parse_expr!("search(way).filter(area() > 10000)")

      assert {:search, :way, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :gt, {:geom_func, :area, _}, {:number, 10_000, _}, _}, _}
              ], _} = expr
    end

    test "geometry function: is_closed" do
      expr = parse_expr!("search(way).filter(is_closed())")

      assert {:search, :way, _, [{:method, :filter_expr, {:geom_func, :is_closed, _}, _}], _} = expr
    end

    test "number coercion" do
      expr = parse_expr!(~s|search(node).filter(number(t["lanes"]) >= 2)|)

      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :gte, {:coerce_func, :number, {:tag_access, "lanes", _}, _},
                  {:number, 2, _}, _}, _}
              ], _} = expr
    end

    test "is_number check" do
      expr = parse_expr!(~s|search(node).filter(is_number(t["population"]))|)

      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:coerce_func, :is_number, {:tag_access, "population", _}, _}, _}
              ], _} = expr
    end

    test "string function: starts_with" do
      expr = parse_expr!(~s|search(node).filter(starts_with(t["name"], "St"))|)

      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:str_func, :starts_with, {:tag_access, "name", _}, {:string, "St", _}, _}, _}
              ], _} = expr
    end

    test "string function: size" do
      expr = parse_expr!(~s|search(node).filter(size(t["description"]) > 100)|)

      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :gt, {:str_func, :size, {:tag_access, "description", _}, nil, _},
                  {:number, 100, _}, _}, _}
              ], _} = expr
    end

    test "logical operators: && and ||" do
      expr = parse_expr!(~s|search(way).filter(length() > 5000 && number(t["lanes"]) >= 2)|)

      assert {:search, :way, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :and, {:bin_op, :gt, {:geom_func, :length, _}, {:number, 5000, _}, _},
                  {:bin_op, :gte, {:coerce_func, :number, {:tag_access, "lanes", _}, _},
                   {:number, 2, _}, _}, _}, _}
              ], _} = expr
    end

    test "unary not" do
      expr = parse_expr!(~s|search(way).filter(!is_closed())|)

      assert {:search, :way, _,
              [{:method, :filter_expr, {:unary_op, :not, {:geom_func, :is_closed, _}, _}, _}], _} =
               expr
    end

    test "arithmetic: number + number" do
      expr = parse_expr!(~s|search(node).filter(number(t["a"]) + number(t["b"]) > 10)|)

      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :gt,
                  {:bin_op, :add, {:coerce_func, :number, _, _}, {:coerce_func, :number, _, _}, _},
                  {:number, 10, _}, _}, _}
              ], _} = expr
    end

    test "operator precedence: * before +" do
      expr = parse_expr!(~s|search(node).filter(number(t["a"]) + number(t["b"]) * 2 > 10)|)

      # Should parse as: (a + (b * 2)) > 10, not ((a + b) * 2) > 10
      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :gt, {:bin_op, :add, _a, {:bin_op, :mul, _b, {:number, 2, _}, _}, _},
                  {:number, 10, _}, _}, _}
              ], _} = expr
    end

    test "parenthesized expression" do
      expr = parse_expr!(~s|search(node).filter((number(t["a"]) + number(t["b"])) * 2 > 10)|)

      # Should parse as: ((a + b) * 2) > 10
      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:bin_op, :gt, {:bin_op, :mul, {:bin_op, :add, _, _, _}, {:number, 2, _}, _},
                  {:number, 10, _}, _}, _}
              ], _} = expr
    end

    test "comparison operators" do
      for {op_str, op_atom} <- [
            {"==", :eq},
            {"!=", :neq},
            {">", :gt},
            {"<", :lt},
            {">=", :gte},
            {"<=", :lte}
          ] do
        expr = parse_expr!(~s|search(node).filter(number(t["x"]) #{op_str} 5)|)

        assert {:search, :node, _,
                [{:method, :filter_expr, {:bin_op, ^op_atom, _, {:number, 5, _}, _}, _}], _} = expr
      end
    end

    test "str_contains function" do
      expr = parse_expr!(~s|search(node).filter(str_contains(t["cuisine"], "pizza"))|)

      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:str_func, :str_contains, {:tag_access, "cuisine", _}, {:string, "pizza", _}, _},
                 _}
              ], _} = expr
    end

    test "ends_with function" do
      expr = parse_expr!(~s|search(node).filter(ends_with(t["name"], "Street"))|)

      assert {:search, :node, _,
              [
                {:method, :filter_expr,
                 {:str_func, :ends_with, {:tag_access, "name", _}, {:string, "Street", _}, _}, _}
              ], _} = expr
    end
  end

  # ── Aggregation methods ──────────────────────────────────────────

  describe "aggregation methods" do
    test ".sum(number(t[\"capacity\"])) parses correctly" do
      expr = parse_expr!(~s|search(node, amenity: "cafe").sum(number(t["capacity"]))|)

      assert {:search, :node, _filters,
              [
                {:method, :sum, {:coerce_func, :number, {:tag_access, "capacity", _}, _}, _}
              ], _} = expr
    end

    test ".min(t[\"opening_hours\"]) parses correctly" do
      expr = parse_expr!(~s|search(node, amenity: "cafe").min(t["opening_hours"])|)

      assert {:search, :node, _filters, [{:method, :min, {:tag_access, "opening_hours", _}, _}], _} =
               expr
    end

    test ".max(number(t[\"population\"])) parses correctly" do
      expr = parse_expr!(~s|search(node).max(number(t["population"]))|)

      assert {:search, :node, _,
              [
                {:method, :max, {:coerce_func, :number, {:tag_access, "population", _}, _}, _}
              ], _} = expr
    end

    test ".avg(number(t[\"rating\"])) parses correctly" do
      expr = parse_expr!(~s|search(node).avg(number(t["rating"]))|)

      assert {:search, :node, _,
              [
                {:method, :avg, {:coerce_func, :number, {:tag_access, "rating", _}, _}, _}
              ], _} = expr
    end
  end

  # ── Group by ────────────────────────────────────────────────────

  describe "group_by" do
    test ".group_by(t[\"amenity\"]).count() parses correctly" do
      expr = parse_expr!(~s|search(node, amenity: *).group_by(t["amenity"]).count()|)

      assert {:search, :node, [{:exists, "amenity"}],
              [
                {:method, :group_by, {:tag_access, "amenity", _}, _},
                {:method, :count, [], _}
              ], _} = expr
    end

    test ~s|.group_by(t["cuisine"]).avg(number(t["rating"])) parses correctly| do
      expr =
        parse_expr!(
          ~s|search(node, amenity: "cafe").group_by(t["cuisine"]).avg(number(t["rating"]))|
        )

      assert {:search, :node, _,
              [
                {:method, :group_by, {:tag_access, "cuisine", _}, _},
                {:method, :avg, {:coerce_func, :number, {:tag_access, "rating", _}, _}, _}
              ], _} = expr
    end

    test ~s|.group_by(t["key"]).sum(number(t["val"])) parses correctly| do
      expr = parse_expr!(~s|search(node).group_by(t["type"]).sum(number(t["count"]))|)

      assert {:search, :node, _,
              [
                {:method, :group_by, {:tag_access, "type", _}, _},
                {:method, :sum, {:coerce_func, :number, {:tag_access, "count", _}, _}, _}
              ], _} = expr
    end
  end
end
