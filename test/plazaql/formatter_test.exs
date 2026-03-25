defmodule PlazaQL.FormatterTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Formatter
  alias PlazaQL.Parser

  defp parse_and_format(input) do
    {:ok, ast} = Parser.parse(input)
    Formatter.format(ast)
  end

  describe "simple search" do
    test "formats search with no args" do
      assert parse_and_format("$$ = search();") == "$$ = search();\n"
    end

    test "formats search with element type" do
      assert parse_and_format("$$ = search(node);") == "$$ = search(node);\n"
    end

    test "formats search with tag filter" do
      result = parse_and_format(~s|$$ = search(amenity: "cafe");|)
      assert result == ~s|$$ = search(amenity: "cafe");\n|
    end

    test "formats search with type and tag filter" do
      result = parse_and_format(~s|$$ = search(node, amenity: "cafe");|)
      assert result == ~s|$$ = search(node, amenity: "cafe");\n|
    end
  end

  describe "method chain indentation" do
    test "short chain stays on one line" do
      result = parse_and_format(~s|$$ = search(node).limit(count: 5);|)
      assert result == ~s|$$ = search(node).limit(count: 5);\n|
    end

    test "long chain breaks to multi-line with 2-space indent" do
      input =
        ~s|$$ = search(amenity: "cafe").around(distance: 500, geometry: point(38.9, -77.0)).sort(by: :distance).limit(count: 20);|

      result = parse_and_format(input)

      assert result ==
               String.trim_trailing(~s"""
               $$ = search(amenity: "cafe")
                 .around(distance: 500, geometry: point(38.9, -77.0))
                 .sort(by: :distance)
                 .limit(count: 20);
               """) <> "\n"
    end
  end

  describe "variable assignment" do
    test "formats variable assignment" do
      result = parse_and_format(~s|$cafes = search(amenity: "cafe");|)
      assert result == ~s|$cafes = search(amenity: "cafe");\n|
    end
  end

  describe "named output" do
    test "formats $$.name assignment" do
      result = parse_and_format(~s|$$.cafes = search(amenity: "cafe");|)
      assert result == ~s|$$.cafes = search(amenity: "cafe");\n|
    end

    test "formats plain $$ assignment" do
      result = parse_and_format(~s|$$ = search(node);|)
      assert result == ~s|$$ = search(node);\n|
    end
  end

  describe "geometry constructors" do
    test "formats point" do
      result =
        parse_and_format("$$ = search().around(distance: 500, geometry: point(38.9, -77.0));")

      assert result =~ "point(38.9, -77.0)"
    end

    test "formats bbox" do
      result = parse_and_format("$$ = search().within(geometry: bbox(40.7, -74.0, 40.8, -73.9));")
      assert result =~ "bbox(40.7, -74.0, 40.8, -73.9)"
    end

    test "formats linestring" do
      result =
        parse_and_format(
          "$$ = search().within(geometry: linestring(point(38.9, -77.0), point(38.85, -77.05)));"
        )

      assert result =~ "linestring(point(38.9, -77.0), point(38.85, -77.05))"
    end
  end

  describe "set operations" do
    test "formats union" do
      result = parse_and_format(~s|$$ = search(amenity: "restaurant") + search(amenity: "cafe");|)
      assert result == ~s|$$ = search(amenity: "restaurant") + search(amenity: "cafe");\n|
    end

    test "formats difference" do
      result =
        parse_and_format(~s|$$ = search(amenity: "restaurant") - search(name: "McDonald's");|)

      assert result =~ ~s|search(amenity: "restaurant") - search(name: "McDonald's")|
    end
  end

  describe "complex query" do
    test "multi-statement query" do
      input = """
      $cafes = search(node, amenity: "cafe");
      $$ = $cafes;
      """

      result = parse_and_format(input)

      assert result =~ ~s|$cafes = search(node, amenity: "cafe");|
      assert result =~ "$$ = $cafes;"
    end

    test "blank lines between statements" do
      input = """
      $a = search(node);
      $b = search(way);
      $$ = $a;
      """

      result = parse_and_format(input)
      # Statements separated by blank lines
      assert result =~ "$a = search(node);\n\n$b = search(way);\n\n$$ = $a;\n"
    end
  end

  describe "bare expression output" do
    test "formats bare expression without $$" do
      result = parse_and_format(~s|search(amenity: "cafe");|)
      assert result == ~s|search(amenity: "cafe");\n|
    end

    test "formats bare expression with method chain" do
      result = parse_and_format(~s|search(node, amenity: "cafe").limit(10);|)
      assert result == ~s|search(node, amenity: "cafe").limit(10);\n|
    end

    test "formats bare computation" do
      result = parse_and_format(~s|route(mode: "auto");|)
      assert result == ~s|route(mode: "auto");\n|
    end
  end

  describe "round-trip stability" do
    test "format(parse(format(parse(x)))) == format(parse(x))" do
      inputs = [
        ~s|$$ = search(amenity: "cafe");|,
        ~s|$x = search(node, tourism: "hotel");\n$$ = $x;|,
        ~s|$$ = search(amenity: "restaurant") + search(amenity: "cafe");|,
        ~s|$$ = search(node).limit(count: 10);|,
        ~s|search(amenity: "cafe");|,
        ~s|search(node, amenity: "cafe").limit(10);|,
        ~s|route(mode: "auto");|
      ]

      for input <- inputs do
        first_pass = parse_and_format(input)
        second_pass = parse_and_format(first_pass)

        assert first_pass == second_pass,
               "Round-trip failed for: #{input}\nFirst: #{first_pass}\nSecond: #{second_pass}"
      end
    end
  end

  describe "tag filters" do
    test "equals" do
      result = parse_and_format(~s|$$ = search(amenity: "cafe");|)
      assert result =~ ~s|amenity: "cafe"|
    end

    test "not equals" do
      result = parse_and_format(~s|$$ = search(amenity: !"fast_food");|)
      assert result =~ ~s|amenity: !"fast_food"|
    end

    test "regex" do
      result = parse_and_format(~s|$$ = search(name: ~"^Starbucks");|)
      assert result =~ ~s|name: ~"^Starbucks"|
    end

    test "case-insensitive regex" do
      result = parse_and_format(~s|$$ = search(name: ~i"starbucks");|)
      assert result =~ ~s|name: ~i"starbucks"|
    end

    test "negated regex" do
      result = parse_and_format(~s|$$ = search(name: !~"McDonald");|)
      assert result =~ ~s|name: !~"McDonald"|
    end

    test "exists" do
      result = parse_and_format("$$ = search(amenity: *);")
      assert result =~ "amenity: *"
    end

    test "not exists" do
      result = parse_and_format("$$ = search(amenity: !*);")
      assert result =~ "amenity: !*"
    end
  end

  describe "filter method" do
    test "formats .filter() with tag filters" do
      input = ~s|$$ = search(node).filter(wheelchair: "yes", cuisine: ~"italian");|
      result = parse_and_format(input)
      assert result =~ ~s|.filter(wheelchair: "yes", cuisine: ~"italian")|
    end
  end

  describe "route" do
    test "formats route with keyword args" do
      input = ~s|$$ = route(mode: "auto");|
      result = parse_and_format(input)
      assert result == ~s|$$ = route(mode: "auto");\n|
    end
  end

  describe "computation functions" do
    test "formats geocode" do
      result = parse_and_format(~s|$$ = geocode(query: "New York");|)
      assert result == ~s|$$ = geocode(query: "New York");\n|
    end

    test "formats boundary" do
      result = parse_and_format(~s|$berlin = boundary(name: "Berlin");|)
      assert result == ~s|$berlin = boundary(name: "Berlin");\n|
    end
  end

  describe "parenthesized set operations with methods" do
    test "wraps set op in parens when chained" do
      input = ~s|(search(amenity: "restaurant") + search(amenity: "cafe")).limit(count: 10);|
      # This is a chain on a union, should get parens
      {:ok, ast} = Parser.parse("$$ = #{input}")
      result = Formatter.format(ast)
      assert result =~ "(search(amenity: \"restaurant\") + search(amenity: \"cafe\"))"
    end
  end

  describe "list literals" do
    test "formats list" do
      input =
        ~s|$$ = matrix(origins: [point(38.9, -77.0), point(38.85, -77.05)], destinations: [point(38.88, -77.02)], mode: "foot");|

      result = parse_and_format(input)
      assert result =~ "[point(38.9, -77.0), point(38.85, -77.05)]"
      assert result =~ "[point(38.88, -77.02)]"
    end
  end

  describe "no-arg methods" do
    test "formats count" do
      result = parse_and_format("$$ = search(node).count();")
      # count is parsed as no_arg_method (no parens needed in source) but we output with parens
      assert result =~ ".count()"
    end
  end

  describe "identifiers as values" do
    test "formats atom in method arg" do
      result = parse_and_format("$$ = search(node).sort(by: :distance);")
      assert result =~ "sort(by: :distance)"
    end
  end

  describe "atom literals" do
    test "formats atom" do
      result = parse_and_format("$$ = search(node).sort(by: :distance);")
      assert result =~ ":distance"
    end
  end

  describe "string escaping" do
    test "preserves escaped quotes" do
      result = parse_and_format(~s|$$ = search(name: "Joe\\"s");|)
      assert result =~ ~s|name: "Joe\\"s"|
    end
  end

  # ── Bracket references ──────────────────────────────────────────

  describe "bracket references" do
    test "$var[attr] round-trips" do
      result = parse_and_format("$$ = $stop[route_id];")
      assert result == "$$ = $stop[route_id];\n"
    end

    test "$$.name[attr] round-trips" do
      result = parse_and_format("$$ = $$.routes[ref];")
      assert result == "$$ = $$.routes[ref];\n"
    end

    test "bracket ref as tag filter value round-trips" do
      result = parse_and_format(~s|$$ = search(node, route_id: $stop[route_id]);|)
      assert result == ~s|$$ = search(node, route_id: $stop[route_id]);\n|
    end
  end

  # ── Join methods ────────────────────────────────────────────────

  describe "join methods" do
    test "member_of with var ref round-trips" do
      result = parse_and_format("$$ = search(node).member_of($route);")
      assert result == "$$ = search(node).member_of($route);\n"
    end

    test "has_member round-trips" do
      result = parse_and_format("$$ = search(relation).has_member($stops);")
      assert result == "$$ = search(relation).has_member($stops);\n"
    end

    test "member_of with role kwarg" do
      result = parse_and_format(~s|$$ = search(node).member_of($route, role: "stop");|)
      assert result == ~s|$$ = search(node).member_of($route, role: "stop");\n|
    end
  end

  # ── Narrowing methods ──────────────────────────────────────────

  describe "narrowing methods" do
    test ".first() round-trips" do
      result = parse_and_format("$$ = search(node).first();")
      assert result == "$$ = search(node).first();\n"
    end

    test ".last() round-trips" do
      result = parse_and_format("$$ = search(node).last();")
      assert result == "$$ = search(node).last();\n"
    end

    test ".index(3) round-trips" do
      result = parse_and_format("$$ = search(node).index(3);")
      assert result == "$$ = search(node).index(3);\n"
    end
  end

  # ── Plan 1: Core gaps ──────────────────────────────────────────

  describe "ID filter formatting" do
    test "numeric ID" do
      result = parse_and_format(~s|$$ = search(node, id: 12345);|)
      assert result == "$$ = search(node, id: 12345);\n"
    end

    test "ID list" do
      result = parse_and_format(~s|$$ = search(node, id: [1, 2, 3]);|)
      assert result == "$$ = search(node, id: [1, 2, 3]);\n"
    end
  end

  describe "key regex formatting" do
    test "key+value regex" do
      result = parse_and_format(~s|$$ = search(node, ~"^addr:": ~"^[0-9]");|)
      assert result == ~s|$$ = search(node, ~"^addr:": ~"^[0-9]");\n|
    end

    test "key regex with wildcard" do
      result = parse_and_format(~s|$$ = search(node, ~"^name:": *);|)
      assert result == ~s|$$ = search(node, ~"^name:": *);\n|
    end
  end

  describe "intersection formatting" do
    test "formats & operator" do
      input = """
      $cafes = search(node, amenity: "cafe");
      $italian = search(node, cuisine: "italian");
      $$ = $cafes & $italian;
      """

      result = parse_and_format(input)
      assert result =~ "& $italian"
    end
  end

  describe "directive formatting" do
    test "formats #bbox directive" do
      input = """
      #bbox(47, 10, 48, 11);
      search(node, amenity: "cafe");
      """

      result = parse_and_format(input)
      assert result =~ "#bbox(47, 10, 48, 11);"
    end

    test "formats #limit directive" do
      result = parse_and_format("#limit(10);\nsearch(node);\n")
      assert result =~ "#limit(10);"
    end

    test "formats #filter tag directive" do
      result = parse_and_format("#filter(amenity: *);\nsearch(node);\n")
      assert result =~ "#filter(amenity: *);"
    end

    test "formats #within directive" do
      result = parse_and_format("#within(boundary(name: \"Berlin\"));\nsearch(node);\n")
      assert result =~ "#within(boundary(name: \"Berlin\"));"
    end
  end

  describe "geom method formatting" do
    test "formats .geom()" do
      result = parse_and_format(~s|$$ = search(node).geom();|)
      assert result == "$$ = search(node).geom();\n"
    end
  end

  describe "expression filter formatting" do
    test "tag access" do
      result = parse_and_format(~s|search(node).filter(t["amenity"] == "cafe");|)
      assert result =~ ~s|filter(t["amenity"] == "cafe")|
    end

    test "property accessor" do
      result = parse_and_format(~s|search(node).filter(id() > 1000);|)
      assert result =~ "filter(id() > 1000)"
    end

    test "geometry function" do
      result = parse_and_format(~s|search(way).filter(length() > 5000);|)
      assert result =~ "filter(length() > 5000)"
    end

    test "number coercion" do
      result = parse_and_format(~s|search(node).filter(number(t["lanes"]) >= 2);|)
      assert result =~ ~s|filter(number(t["lanes"]) >= 2)|
    end

    test "logical operators" do
      result = parse_and_format(~s|search(way).filter(length() > 5000 && is_closed());|)
      assert result =~ "filter(length() > 5000 && is_closed())"
    end

    test "unary not" do
      result = parse_and_format(~s|search(way).filter(!is_closed());|)
      assert result =~ "filter(!is_closed())"
    end

    test "string functions" do
      result = parse_and_format(~s|search(node).filter(starts_with(t["name"], "St"));|)
      assert result =~ ~s|filter(starts_with(t["name"], "St"))|
    end

    test "size function" do
      result = parse_and_format(~s|search(node).filter(size(t["desc"]) > 10);|)
      assert result =~ ~s|filter(size(t["desc"]) > 10)|
    end

    test "complex expression round-trip" do
      input = ~s|search(way).filter(number(t["lanes"]) * 2 + 1 > 5);|
      result = parse_and_format(input)
      assert result =~ ~s|filter(number(t["lanes"]) * 2 + 1 > 5)|
    end
  end

  # ── Aggregation formatting ──────────────────────────────────────

  describe "aggregation formatting" do
    test "sum round-trip" do
      input = ~s|search(node, amenity: "cafe").sum(number(t["capacity"]));|
      result = parse_and_format(input)
      assert result =~ ~s|.sum(number(t["capacity"]))|
    end

    test "min round-trip" do
      input = ~s|search(node).min(t["name"]);|
      result = parse_and_format(input)
      assert result =~ ~s|.min(t["name"])|
    end

    test "max round-trip" do
      input = ~s|search(node).max(number(t["population"]));|
      result = parse_and_format(input)
      assert result =~ ~s|.max(number(t["population"]))|
    end

    test "avg round-trip" do
      input = ~s|search(node).avg(number(t["rating"]));|
      result = parse_and_format(input)
      assert result =~ ~s|.avg(number(t["rating"]))|
    end

    test "group_by + count round-trip" do
      input = ~s|search(node, amenity: *).group_by(t["amenity"]).count();|
      result = parse_and_format(input)
      assert result =~ ~s|.group_by(t["amenity"]).count()|
    end

    test "group_by + avg round-trip" do
      input = ~s|search(node, amenity: "cafe").group_by(t["cuisine"]).avg(number(t["rating"]));|
      result = parse_and_format(input)
      assert result =~ ~s|.group_by(t["cuisine"]).avg(number(t["rating"]))|
    end
  end
end
