defmodule PlazaQL.SQL.ExpressionTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Schema
  alias PlazaQL.SQL.Expression

  defp expr_sql(expr, schema \\ Schema.new()) do
    Expression.to_sql(expr, schema)
  end

  # ── Binary operators ────────────────────────────────────────────────

  describe "binary operators" do
    test "and" do
      expr = {:bin_op, :and, {:bool, true, nil}, {:bool, false, nil}, nil}
      assert {"(TRUE AND FALSE)", [], 1} = expr_sql(expr)
    end

    test "or" do
      expr = {:bin_op, :or, {:bool, true, nil}, {:bool, false, nil}, nil}
      assert {"(TRUE OR FALSE)", [], 1} = expr_sql(expr)
    end

    test "eq" do
      expr = {:bin_op, :eq, {:number, 1, nil}, {:number, 2, nil}, nil}
      assert {"($1 = $2)", [1, 2], 3} = expr_sql(expr)
    end

    test "neq" do
      expr = {:bin_op, :neq, {:number, 1, nil}, {:number, 2, nil}, nil}
      assert {"($1 != $2)", [1, 2], 3} = expr_sql(expr)
    end

    test "gt" do
      expr = {:bin_op, :gt, {:number, 5, nil}, {:number, 3, nil}, nil}
      assert {"($1 > $2)", [5, 3], 3} = expr_sql(expr)
    end

    test "lt" do
      expr = {:bin_op, :lt, {:number, 1, nil}, {:number, 2, nil}, nil}
      assert {"($1 < $2)", [1, 2], 3} = expr_sql(expr)
    end

    test "gte" do
      expr = {:bin_op, :gte, {:number, 5, nil}, {:number, 5, nil}, nil}
      assert {"($1 >= $2)", [5, 5], 3} = expr_sql(expr)
    end

    test "lte" do
      expr = {:bin_op, :lte, {:number, 3, nil}, {:number, 7, nil}, nil}
      assert {"($1 <= $2)", [3, 7], 3} = expr_sql(expr)
    end

    test "add" do
      expr = {:bin_op, :add, {:number, 1, nil}, {:number, 2, nil}, nil}
      assert {"($1 + $2)", [1, 2], 3} = expr_sql(expr)
    end

    test "sub" do
      expr = {:bin_op, :sub, {:number, 10, nil}, {:number, 3, nil}, nil}
      assert {"($1 - $2)", [10, 3], 3} = expr_sql(expr)
    end

    test "mul" do
      expr = {:bin_op, :mul, {:number, 4, nil}, {:number, 5, nil}, nil}
      assert {"($1 * $2)", [4, 5], 3} = expr_sql(expr)
    end

    test "div wraps right in NULLIF" do
      expr = {:bin_op, :div, {:number, 10, nil}, {:number, 2, nil}, nil}
      assert {"($1 / NULLIF($2, 0))", [10, 2], 3} = expr_sql(expr)
    end
  end

  # ── Unary operators ─────────────────────────────────────────────────

  describe "unary operators" do
    test "not" do
      expr = {:unary_op, :not, {:bool, true, nil}, nil}
      assert {"NOT (TRUE)", [], 1} = expr_sql(expr)
    end

    test "neg" do
      expr = {:unary_op, :neg, {:number, 42, nil}, nil}
      assert {"-($1)", [42], 2} = expr_sql(expr)
    end
  end

  # ── Tag access ──────────────────────────────────────────────────────

  describe "tag access" do
    test "generates jsonb text extraction" do
      expr = {:tag_access, "name", nil}
      assert {"tags ->> $1", ["name"], 2} = expr_sql(expr)
    end

    test "uses schema column name" do
      schema = Schema.new(tags_column: "properties")
      expr = {:tag_access, "highway", nil}
      assert {"properties ->> $1", ["highway"], 2} = expr_sql(expr, schema)
    end
  end

  # ── Property accessors ─────────────────────────────────────────────

  describe "property accessors" do
    test "id returns column name" do
      expr = {:prop_access, :id, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "osm_id"
      assert params == []
    end

    test "lat returns ST_Y" do
      expr = {:prop_access, :lat, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "ST_Y(geom)"
      assert params == []
    end

    test "lon returns ST_X" do
      expr = {:prop_access, :lon, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "ST_X(geom)"
      assert params == []
    end

    test "type raises ArgumentError" do
      expr = {:prop_access, :type, nil}
      assert_raise ArgumentError, ~r/type property/, fn -> expr_sql(expr) end
    end

    test "uses custom geometry column" do
      schema = Schema.new(geometry_column: "the_geom")
      expr = {:prop_access, :lat, nil}
      {sql, _, _} = expr_sql(expr, schema)
      assert sql == "ST_Y(the_geom)"
    end
  end

  # ── Geometry functions ──────────────────────────────────────────────

  describe "geometry functions" do
    test "length" do
      expr = {:geom_func, :length, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "ST_Length(geom::geography)"
      assert params == []
    end

    test "area" do
      expr = {:geom_func, :area, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "ST_Area(geom::geography)"
      assert params == []
    end

    test "is_closed" do
      expr = {:geom_func, :is_closed, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "ST_IsClosed(geom)"
      assert params == []
    end

    test "distance parameterizes point" do
      expr = {:geom_func, :distance, {40.7, -74.0}, nil}
      {sql, params, next_idx} = expr_sql(expr)
      assert sql =~ "ST_Distance"
      assert sql =~ "ST_MakePoint($1, $2)"
      assert sql =~ "4326"
      # lng first, lat second in params
      assert params == [-74.0, 40.7]
      assert next_idx == 3
    end

    test "elevation uses schema elevation_table" do
      schema = Schema.new(elevation_table: "elevation_raster")
      expr = {:geom_func, :elevation, nil}
      {sql, params, _} = expr_sql(expr, schema)
      assert sql =~ "elevation_raster"
      assert sql =~ "ST_Value"
      assert sql =~ "ST_Intersects"
      assert params == []
    end

    test "elevation raises without elevation_table" do
      expr = {:geom_func, :elevation, nil}
      assert_raise ArgumentError, ~r/elevation_table/, fn -> expr_sql(expr) end
    end
  end

  # ── Type coercion ───────────────────────────────────────────────────

  describe "type coercion" do
    test "number casts to numeric" do
      expr = {:coerce_func, :number, {:tag_access, "population", nil}, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "(tags ->> $1)::numeric"
      assert params == ["population"]
    end

    test "is_number produces regex check" do
      expr = {:coerce_func, :is_number, {:tag_access, "lanes", nil}, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql =~ "tags ->> $1"
      assert sql =~ "~ $2"
      assert params == ["lanes", "^-?[0-9]+(\\.[0-9]+)?$"]
    end
  end

  # ── String functions ────────────────────────────────────────────────

  describe "string functions" do
    test "starts_with" do
      expr = {:str_func, :starts_with, {:tag_access, "name", nil}, {:string, "Oak", nil}, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql =~ "LIKE"
      assert sql =~ "|| '%'"
      assert sql =~ "replace("
      assert "name" in params
      assert "Oak" in params
    end

    test "ends_with" do
      expr = {:str_func, :ends_with, {:tag_access, "name", nil}, {:string, "Ave", nil}, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql =~ "LIKE '%' ||"
      assert "name" in params
      assert "Ave" in params
    end

    test "str_contains" do
      expr = {:str_func, :str_contains, {:tag_access, "name", nil}, {:string, "Main", nil}, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql =~ "LIKE '%' ||"
      assert sql =~ "|| '%'"
      assert "name" in params
      assert "Main" in params
    end

    test "size returns char_length" do
      expr = {:str_func, :size, {:tag_access, "name", nil}, nil, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "char_length(tags ->> $1)"
      assert params == ["name"]
    end
  end

  # ── Literals ────────────────────────────────────────────────────────

  describe "literals" do
    test "number" do
      assert {"$1", [42], 2} = expr_sql({:number, 42, nil})
    end

    test "float number" do
      assert {"$1", [3.14], 2} = expr_sql({:number, 3.14, nil})
    end

    test "string" do
      assert {"$1", ["hello"], 2} = expr_sql({:string, "hello", nil})
    end

    test "bool true" do
      assert {"TRUE", [], 1} = expr_sql({:bool, true, nil})
    end

    test "bool false" do
      assert {"FALSE", [], 1} = expr_sql({:bool, false, nil})
    end
  end

  # ── Nested expressions ─────────────────────────────────────────────

  describe "nested expressions" do
    test "length > number" do
      expr = {:bin_op, :gt, {:geom_func, :length, nil}, {:number, 100, nil}, nil}
      {sql, params, next_idx} = expr_sql(expr)
      assert sql == "(ST_Length(geom::geography) > $1)"
      assert params == [100]
      assert next_idx == 2
    end

    test "deeply nested arithmetic" do
      # (1 + 2) * 3
      inner = {:bin_op, :add, {:number, 1, nil}, {:number, 2, nil}, nil}
      expr = {:bin_op, :mul, inner, {:number, 3, nil}, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "(($1 + $2) * $3)"
      assert params == [1, 2, 3]
    end

    test "tag comparison with coercion" do
      # number(tags.population) > 1000000
      coerced = {:coerce_func, :number, {:tag_access, "population", nil}, nil}
      expr = {:bin_op, :gt, coerced, {:number, 1_000_000, nil}, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "((tags ->> $1)::numeric > $2)"
      assert params == ["population", 1_000_000]
    end

    test "and with nested comparisons" do
      left = {:bin_op, :eq, {:tag_access, "highway", nil}, {:string, "primary", nil}, nil}
      right = {:bin_op, :gt, {:geom_func, :length, nil}, {:number, 500, nil}, nil}
      expr = {:bin_op, :and, left, right, nil}
      {sql, params, _} = expr_sql(expr)
      assert sql == "((tags ->> $1 = $2) AND (ST_Length(geom::geography) > $3))"
      assert params == ["highway", "primary", 500]
    end
  end

  # ── Schema customization ───────────────────────────────────────────

  describe "schema customization" do
    test "custom column names affect tag access" do
      schema = Schema.new(tags_column: "properties", geometry_column: "the_geom", id_column: "gid")
      assert {"properties ->> $1", ["name"], 2} = expr_sql({:tag_access, "name", nil}, schema)
    end

    test "custom id column" do
      schema = Schema.new(id_column: "gid")
      {sql, _, _} = expr_sql({:prop_access, :id, nil}, schema)
      assert sql == "gid"
    end

    test "custom geometry column in ST functions" do
      schema = Schema.new(geometry_column: "the_geom")
      {sql, _, _} = expr_sql({:geom_func, :area, nil}, schema)
      assert sql == "ST_Area(the_geom::geography)"
    end

    test "custom SRID in distance" do
      schema = Schema.new(srid: 3857)
      expr = {:geom_func, :distance, {40.7, -74.0}, nil}
      {sql, _, _} = expr_sql(expr, schema)
      assert sql =~ "3857"
      refute sql =~ "4326"
    end
  end

  # ── Fallback ────────────────────────────────────────────────────────

  describe "fallback" do
    test "raises on unknown node" do
      assert_raise ArgumentError, ~r/unhandled expression node/, fn ->
        expr_sql({:unknown, :stuff, nil})
      end
    end
  end
end
