defmodule PlazaQL.LibraryUsageTest do
  @moduledoc """
  The README's "Using the Elixir library" examples, run as written (SQL
  generation only; no database).
  """
  use ExUnit.Case, async: true

  alias PlazaQL.Plan
  alias PlazaQL.Query
  alias PlazaQL.Schema

  @cafes ~s|search(node, amenity: "cafe").bbox(38.8, -77.1, 39.0, -76.9);|

  test "one query from source" do
    assert {:ok, %Query{sql: sql, params: params}} = PlazaQL.query(@cafes)
    assert sql =~ "FROM osm_nodes WHERE geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)"
    assert params == [-77.1, 38.8, -76.9, 39.0, "amenity", "amenity", "cafe"]
  end

  test "a custom schema" do
    schema =
      Schema.new(
        tables: [node: "points", way: "lines", relation: "areas"],
        columns: [id: "id", geometry: "geometry", tags: "tags"],
        srid: 4326
      )

    assert {:ok, %Query{sql: sql}} = PlazaQL.query(@cafes, schema: schema)
    assert sql =~ "SELECT id, tags, geometry, 'node' AS __type__ FROM points WHERE geometry && "
  end

  test "extra conditions" do
    {:ok, %{plans: [plan]}} = PlazaQL.compile(~s|search(node, amenity: "cafe");|)

    plan = %{plan | custom_clauses: [{"updated_at > $1", [~U[2026-01-01 00:00:00Z]]}]}
    assert {:ok, %Query{sql: sql, params: params}} = PlazaQL.to_sql(plan)
    assert sql =~ "AND updated_at > $4"
    assert List.last(params) == ~U[2026-01-01 00:00:00Z]
  end

  test "step by step" do
    {:ok, ast} = PlazaQL.parse(@cafes)
    {:ok, checked} = PlazaQL.TypeChecker.check(ast)
    {:ok, %{plans: plans, steps: _steps}} = PlazaQL.Compiler.compile(checked)

    assert {:ok, %Query{}} = PlazaQL.to_sql(hd(plans), Schema.new())
  end

  test "computations are not compiled to SQL" do
    {:ok, %{plans: [plan]}} =
      PlazaQL.compile(~s|route(origin: point(40.71, -74.0), destination: point(40.75, -73.98));|)

    assert {:error, %PlazaQL.NotCompilable{reason: :route}} = PlazaQL.to_sql(plan)
  end

  test "a variable reference compiles once the caller resolves it" do
    {:ok, %{plans: [plan]}} =
      PlazaQL.compile(~s|$area = boundary(name: "Paris"); search(node).within($area);|)

    assert {:error, %PlazaQL.NotCompilable{}} = PlazaQL.to_sql(plan)

    resolved = %Plan{
      plan
      | spatial_filter: {:predicate, :within, {:ewkt, "SRID=4326;POLYGON((0 0,1 0,1 1,0 0))"}}
    }

    assert {:ok, %Query{sql: sql}} = PlazaQL.to_sql(resolved)
    assert sql =~ "ST_CoveredBy(geom, ST_GeomFromEWKT($1))"
  end

  test "pagination resumes after the last row" do
    {:ok, %{plans: [plan]}} = PlazaQL.compile(~s|search(node, amenity: "cafe").limit(10);|)

    assert {:ok, %Query{sql: sql, params: params}} = PlazaQL.to_sql(%{plan | seek: {nil, 0, 1234}})
    assert sql =~ "osm_id > $4"
    assert 1234 in params
  end

  test "one query per branch" do
    {:ok, %{plans: [plan]}} = PlazaQL.compile(~s|search(nwr, amenity: "cafe").limit(5);|)

    assert {:ok, [node: %Query{}, way: %Query{}, relation: %Query{}]} = PlazaQL.SQL.branches(plan)
    assert {:ok, [_, _, _]} = PlazaQL.branches(plan)
  end
end
