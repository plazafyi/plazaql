defmodule PlazaQL.SQL.WhereTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Plan
  alias PlazaQL.Schema
  alias PlazaQL.SQL.Where

  @default_schema Schema.new()

  @h3_schema Schema.new(
               tile_id_column: "tile_id",
               extensions: [h3: true]
             )

  @full_schema Schema.new(
                 tile_id_column: "tile_id",
                 partition_tile_id_column: "partition_tile_id",
                 admin_boundaries_table: "admin_boundaries",
                 extensions: [h3: true, partition_pruning: true]
               )

  defp plan(overrides \\ %{}) do
    struct(%Plan{}, overrides)
  end

  # ── Empty plan ───────────────────────────────────────────────────

  describe "build_where/3 with empty plan" do
    test "returns empty string when no filters" do
      assert {"", [], 1} = Where.build_where(plan(), @default_schema)
    end

    test "respects start index" do
      assert {"", [], 5} = Where.build_where(plan(), @default_schema, 5)
    end
  end

  # ── Tag filters ──────────────────────────────────────────────────

  describe "tag filter: eq" do
    test "generates key existence + value match" do
      p = plan(%{tag_filters: [{:eq, "highway", "primary"}]})
      {sql, params, next_idx} = Where.build_where(p, @default_schema)

      assert sql =~ "WHERE"
      assert sql =~ "tags ? $1"
      assert sql =~ "tags->>$2 = $3"
      assert params == ["highway", "highway", "primary"]
      assert next_idx == 4
    end
  end

  describe "tag filter: neq" do
    test "generates inequality with OR NOT exists" do
      p = plan(%{tag_filters: [{:neq, "access", "private"}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "tags->>$1 != $2"
      assert sql =~ "NOT tags ? $3"
      assert params == ["access", "private", "access"]
    end
  end

  describe "tag filter: exists" do
    test "generates key existence check" do
      p = plan(%{tag_filters: [{:exists, "name"}]})
      {sql, params, next_idx} = Where.build_where(p, @default_schema)

      assert sql == "WHERE tags ? $1"
      assert params == ["name"]
      assert next_idx == 2
    end
  end

  describe "tag filter: not_exists" do
    test "generates negated key existence" do
      p = plan(%{tag_filters: [{:not_exists, "toll"}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql == "WHERE NOT tags ? $1"
      assert params == ["toll"]
    end
  end

  describe "tag filter: regex" do
    test "generates POSIX regex match" do
      p = plan(%{tag_filters: [{:regex, "name", "^Mc"}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "tags->>$1 ~ $2"
      assert params == ["name", "^Mc"]
    end
  end

  describe "tag filter: regex_i" do
    test "generates case-insensitive POSIX regex" do
      p = plan(%{tag_filters: [{:regex_i, "name", "street"}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "tags->>$1 ~* $2"
      assert params == ["name", "street"]
    end
  end

  describe "tag filter: not_regex" do
    test "generates negated regex with existence check" do
      p = plan(%{tag_filters: [{:not_regex, "name", "test"}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "NOT (tags ? $1 AND tags->>$2 ~ $3)"
      assert params == ["name", "name", "test"]
    end
  end

  describe "tag filter: any_of" do
    test "generates ANY array match" do
      p = plan(%{tag_filters: [{:any_of, "highway", ["primary", "secondary"]}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "tags ? $1"
      assert sql =~ "tags->>$2 = ANY($3::text[])"
      assert params == ["highway", "highway", ["primary", "secondary"]]
    end
  end

  describe "tag filter: impossible" do
    test "generates FALSE" do
      p = plan(%{tag_filters: [:impossible]})
      {sql, params, next_idx} = Where.build_where(p, @default_schema)

      assert sql == "WHERE FALSE"
      assert params == []
      assert next_idx == 1
    end
  end

  describe "tag filter: is_in" do
    test "generates EXISTS subquery against admin boundaries" do
      p = plan(%{tag_filters: [{:is_in, "Berlin"}]})
      {sql, params, _} = Where.build_where(p, @full_schema)

      assert sql =~ "EXISTS (SELECT 1 FROM admin_boundaries ab"
      assert sql =~ "ab.name = $1"
      assert sql =~ "ST_Contains(ab.geom, geom)"
      assert params == ["Berlin"]
    end

    test "raises without admin_boundaries table" do
      p = plan(%{tag_filters: [{:is_in, "Berlin"}]})

      assert_raise ArgumentError, ~r/admin_boundaries/, fn ->
        Where.build_where(p, @default_schema)
      end
    end
  end

  describe "tag filter: key_value_regex" do
    test "generates EXISTS with jsonb_each_text" do
      p = plan(%{tag_filters: [{:key_value_regex, "^addr:", "^1"}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "jsonb_each_text(tags)"
      assert sql =~ "kv.key ~ $1"
      assert sql =~ "kv.value ~ $2"
      assert params == ["^addr:", "^1"]
    end
  end

  describe "tag filter: key_regex_exists" do
    test "generates EXISTS with jsonb_object_keys" do
      p = plan(%{tag_filters: [{:key_regex_exists, "^name:"}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "jsonb_object_keys(tags)"
      assert sql =~ "k ~ $1"
      assert params == ["^name:"]
    end
  end

  describe "tag filter: bracket_eq" do
    test "generates placeholder bracket reference" do
      p = plan(%{tag_filters: [{:bracket_eq, "ref", "routes", "ref"}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "tags ? $1"
      assert sql =~ "tags->>$2 = $3"
      assert params == ["ref", "ref", "__bracket_ref__"]
    end
  end

  # ── Spatial filters ──────────────────────────────────────────────

  describe "spatial filter: bbox" do
    test "generates ST_MakeEnvelope" do
      p = plan(%{spatial_filter: {:bbox, 40.0, -74.0, 41.0, -73.0}})
      {sql, params, next_idx} = Where.build_where(p, @default_schema)

      assert sql =~ "geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)"
      assert params == [-74.0, 40.0, -73.0, 41.0]
      assert next_idx == 5
    end

    test "handles antimeridian crossing (west > east)" do
      p = plan(%{spatial_filter: {:bbox, -10.0, 170.0, 10.0, -170.0}})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_MakeEnvelope($1, $2, 180, $3, 4326)"
      assert sql =~ "ST_MakeEnvelope(-180, $4, $5, $6, 4326)"
      assert sql =~ " OR "
      assert params == [170.0, -10.0, 10.0, -10.0, -170.0, 10.0]
    end
  end

  describe "spatial filter: around" do
    test "generates ST_DWithin" do
      p = plan(%{spatial_filter: {:around, 48.8566, 2.3522, 1000.0}})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_DWithin(geom::geography, ST_Point($1, $2, 4326)::geography, $3)"
      assert params == [2.3522, 48.8566, 1000.0]
    end
  end

  describe "spatial filter: h3" do
    test "generates h3 containment check" do
      p = plan(%{spatial_filter: {:h3, "8928308280fffff"}})
      {sql, params, _} = Where.build_where(p, @h3_schema)

      assert sql =~ "tile_id <@ $1::h3index"
      assert sql =~ "tile_id @> $1::h3index"
      assert params == ["8928308280fffff"]
    end

    test "raises without tile_id column" do
      p = plan(%{spatial_filter: {:h3, "8928308280fffff"}})

      assert_raise ArgumentError, ~r/tile_id/, fn ->
        Where.build_where(p, @default_schema)
      end
    end
  end

  describe "spatial filter: polygon" do
    test "generates ST_Within with WKT" do
      coords = [{40.0, -74.0}, {41.0, -74.0}, {41.0, -73.0}, {40.0, -73.0}]
      p = plan(%{spatial_filter: {:polygon, coords}})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_Within(geom, ST_GeomFromText($1, 4326))"
      assert [wkt] = params
      assert wkt =~ "POLYGON(("
    end

    test "auto-closes polygon ring" do
      coords = [{40.0, -74.0}, {41.0, -74.0}, {41.0, -73.0}]
      p = plan(%{spatial_filter: {:polygon, coords}})
      {_sql, [wkt], _} = Where.build_where(p, @default_schema)

      # Ring is closed by appending first point (lng lat order)
      assert wkt =~ "40.0 -74.0)"
    end

    test "does not double-close already-closed ring" do
      coords = [{40.0, -74.0}, {41.0, -74.0}, {41.0, -73.0}, {40.0, -74.0}]
      p = plan(%{spatial_filter: {:polygon, coords}})
      {_sql, [wkt], _} = Where.build_where(p, @default_schema)

      # Should not have duplicate closing point
      ring =
        wkt
        |> String.trim_leading("POLYGON((")
        |> String.trim_trailing("))")

      points = String.split(ring, ", ")
      assert length(points) == 4
    end
  end

  describe "spatial filter: around_set_resolved" do
    test "generates ST_DWithin with geometry collection" do
      ewkts = ["SRID=4326;POINT(2.0 48.0)", "SRID=4326;POINT(3.0 49.0)"]
      p = plan(%{spatial_filter: {:around_set_resolved, ewkts, 500.0}})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_DWithin"
      assert sql =~ "ST_GeomFromEWKT($1)"
      assert [collection_wkt, 500.0] = params
      assert collection_wkt =~ "GEOMETRYCOLLECTION"
      assert collection_wkt =~ "POINT(2.0 48.0)"
    end
  end

  describe "spatial filter: predicate" do
    test "within predicate" do
      geom = {:point, 2.3522, 48.8566}
      p = plan(%{spatial_filter: {:predicate, :within, geom}})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_Within(geom, ST_GeomFromEWKT($1))"
      refute sql =~ "NOT"
      assert [ewkt] = params
      assert ewkt =~ "SRID=4326;POINT(2.3522 48.8566)"
    end

    test "intersects predicate" do
      geom = {:point, 0.0, 0.0}
      p = plan(%{spatial_filter: {:predicate, :intersects, geom}})
      {sql, _, _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_Intersects(geom"
    end

    test "contains predicate" do
      geom = {:point, 0.0, 0.0}
      p = plan(%{spatial_filter: {:predicate, :contains, geom}})
      {sql, _, _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_Contains(geom"
    end

    test "crosses predicate" do
      geom = {:linestring, [{0.0, 0.0}, {1.0, 1.0}]}
      p = plan(%{spatial_filter: {:predicate, :crosses, geom}})
      {sql, [ewkt], _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_Crosses(geom"
      assert ewkt =~ "LINESTRING"
    end

    test "touches predicate" do
      geom = {:point, 0.0, 0.0}
      p = plan(%{spatial_filter: {:predicate, :touches, geom}})
      {sql, _, _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_Touches(geom"
    end

    test "negated predicates" do
      geom = {:point, 0.0, 0.0}

      for pred <- [:not_within, :not_intersects, :not_contains] do
        p = plan(%{spatial_filter: {:predicate, pred, geom}})
        {sql, _, _} = Where.build_where(p, @default_schema)

        assert sql =~ "NOT ST_"
      end
    end

    test "polygon geometry in predicate" do
      geom = {:polygon, [[{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]]}
      p = plan(%{spatial_filter: {:predicate, :within, geom}})
      {_sql, [ewkt], _} = Where.build_where(p, @default_schema)

      assert ewkt =~ "POLYGON"
    end
  end

  # ── Metadata filters ────────────────────────────────────────────

  describe "metadata filters" do
    test "newer filter" do
      dt = ~U[2024-01-01 00:00:00Z]
      p = plan(%{metadata_filters: [{:newer, dt}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql == "WHERE updated_at >= $1"
      assert params == [dt]
    end

    test "version filter" do
      p = plan(%{metadata_filters: [{:version, 3}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql == "WHERE version = $1"
      assert params == [3]
    end

    test "changeset filter" do
      p = plan(%{metadata_filters: [{:changeset, 12_345}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql == "WHERE changeset = $1"
      assert params == [12_345]
    end

    test "multiple metadata filters" do
      dt = ~U[2024-06-01 00:00:00Z]

      p =
        plan(%{metadata_filters: [{:newer, dt}, {:version, 5}]})

      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "updated_at >= $1"
      assert sql =~ "version = $2"
      assert params == [dt, 5]
    end
  end

  # ── OSM IDs ──────────────────────────────────────────────────────

  describe "osm_ids filter" do
    test "generates ANY array match" do
      p = plan(%{osm_ids: [1, 2, 3]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql == "WHERE osm_id = ANY($1)"
      assert params == [[1, 2, 3]]
    end

    test "nil osm_ids produces no clause" do
      p = plan(%{osm_ids: nil})
      assert {"", [], 1} = Where.build_where(p, @default_schema)
    end

    test "empty osm_ids produces no clause" do
      p = plan(%{osm_ids: []})
      assert {"", [], 1} = Where.build_where(p, @default_schema)
    end
  end

  # ── Boundary filter ─────────────────────────────────────────────

  describe "boundary filter" do
    test "adds boundary tag check when :boundary in element_types" do
      p = plan(%{element_types: [:relation, :boundary]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "tags ? 'boundary'"
      assert params == []
    end

    test "no boundary check without :boundary type" do
      p = plan(%{element_types: [:node, :way]})
      assert {"", [], 1} = Where.build_where(p, @default_schema)
    end
  end

  # ── H3 tiles from caller_context ────────────────────────────────

  describe "h3 tile filter" do
    test "generates OR'd containment checks" do
      p = plan(%{caller_context: %{h3_tiles: ["891234", "891235"]}})
      {sql, params, _} = Where.build_where(p, @h3_schema)

      assert sql =~ "tile_id <@ $1::h3index OR tile_id @> $1::h3index"
      assert sql =~ "tile_id <@ $2::h3index OR tile_id @> $2::h3index"
      assert sql =~ " OR "
      assert params == ["891234", "891235"]
    end

    test "wraps multiple tiles in parens" do
      p = plan(%{caller_context: %{h3_tiles: ["a", "b"]}})
      {sql, _, _} = Where.build_where(p, @h3_schema)

      assert sql =~ "WHERE ("
      assert sql =~ ")"
    end

    test "single tile" do
      p = plan(%{caller_context: %{h3_tiles: ["891234"]}})
      {sql, params, _} = Where.build_where(p, @h3_schema)

      assert sql =~ "tile_id <@ $1::h3index"
      assert params == ["891234"]
    end

    test "empty tiles list produces no clause" do
      p = plan(%{caller_context: %{h3_tiles: []}})
      assert {"", [], 1} = Where.build_where(p, @h3_schema)
    end

    test "missing h3_tiles key produces no clause" do
      p = plan(%{caller_context: %{}})
      assert {"", [], 1} = Where.build_where(p, @h3_schema)
    end

    test "raises without tile_id column" do
      p = plan(%{caller_context: %{h3_tiles: ["891234"]}})

      assert_raise ArgumentError, ~r/tile_id/, fn ->
        Where.build_where(p, @default_schema)
      end
    end
  end

  # ── Partition filter from caller_context ────────────────────────

  describe "partition filter" do
    test "generates ANY with bigint array" do
      p = plan(%{caller_context: %{partitions: [100, 200, 300]}})
      {sql, params, _} = Where.build_where(p, @full_schema)

      assert sql =~ "partition_tile_id = ANY($1::bigint[])"
      assert params == [[100, 200, 300]]
    end

    test "empty partitions produces no clause" do
      p = plan(%{caller_context: %{partitions: []}})
      assert {"", [], 1} = Where.build_where(p, @full_schema)
    end

    test "raises without partition_tile_id column" do
      p = plan(%{caller_context: %{partitions: [100]}})

      assert_raise ArgumentError, ~r/partition_tile_id/, fn ->
        Where.build_where(p, @default_schema)
      end
    end
  end

  # ── Custom clauses ──────────────────────────────────────────────

  describe "custom clauses" do
    test "appends raw SQL fragments" do
      p = plan(%{custom_clauses: [{"status = 'active'", []}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql == "WHERE status = 'active'"
      assert params == []
    end

    test "appends with params" do
      p = plan(%{custom_clauses: [{"score > $1", [42]}]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "score > $1"
      assert params == [42]
    end
  end

  # ── Combined filters ────────────────────────────────────────────

  describe "combined filters" do
    test "ANDs multiple filter types together" do
      p =
        plan(%{
          spatial_filter: {:bbox, 40.0, -74.0, 41.0, -73.0},
          tag_filters: [{:exists, "name"}],
          osm_ids: [1, 2, 3]
        })

      {sql, params, _} = Where.build_where(p, @default_schema)

      # All three condition types should be present
      assert sql =~ "geom && ST_MakeEnvelope"
      assert sql =~ "osm_id = ANY"
      assert sql =~ "tags ? $"

      # Should be joined with AND
      parts = String.split(sql, " AND ")
      assert length(parts) == 3

      # Params should be sequential
      # bbox: [-74.0, 40.0, -73.0, 41.0] at $1-$4
      # osm_ids: [[1,2,3]] at $5
      # tag exists: ["name"] at $6
      assert params == [-74.0, 40.0, -73.0, 41.0, [1, 2, 3], "name"]
    end

    test "param indices chain correctly across many filters" do
      dt = ~U[2024-01-01 00:00:00Z]

      p =
        plan(%{
          tag_filters: [{:eq, "highway", "primary"}, {:exists, "name"}],
          metadata_filters: [{:newer, dt}]
        })

      {sql, params, next_idx} = Where.build_where(p, @default_schema)

      # eq: $1 (key), $2 (key), $3 (value) → idx 4
      # exists: $4 (key) → idx 5
      # newer: $5 (dt) → idx 6
      assert params == ["highway", "highway", "primary", "name", dt]
      assert next_idx == 6
      assert sql =~ "$5"
    end

    test "start index offsets all params" do
      p = plan(%{tag_filters: [{:exists, "name"}]})
      {sql, params, next_idx} = Where.build_where(p, @default_schema, 10)

      assert sql == "WHERE tags ? $10"
      assert params == ["name"]
      assert next_idx == 11
    end
  end

  # ── Custom schema column names ──────────────────────────────────

  describe "custom schema names" do
    test "uses custom column names in output" do
      schema =
        Schema.new(
          id_column: "id",
          geometry_column: "geometry",
          tags_column: "properties"
        )

      p =
        plan(%{
          tag_filters: [{:exists, "name"}],
          osm_ids: [42],
          spatial_filter: {:bbox, 0.0, 0.0, 1.0, 1.0}
        })

      {sql, _, _} = Where.build_where(p, schema)

      assert sql =~ "geometry && ST_MakeEnvelope"
      assert sql =~ "id = ANY"
      assert sql =~ "properties ? $"
      refute sql =~ "osm_id"
      refute sql =~ " geom "
      refute sql =~ " tags "
    end

    test "uses custom SRID" do
      schema = Schema.new(srid: 3857)
      p = plan(%{spatial_filter: {:bbox, 0.0, 0.0, 1.0, 1.0}})
      {sql, _, _} = Where.build_where(p, schema)

      assert sql =~ "3857"
      refute sql =~ "4326"
    end
  end

  # ── Filter expressions ──────────────────────────────────────────

  describe "filter expressions" do
    test "delegates to Expression.to_sql" do
      # Simple literal expression that Expression can handle
      expr = {:bin_op, :gt, {:tag_access, "population", nil}, {:number, 1000, nil}, nil}
      p = plan(%{filter_exprs: [expr]})
      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "tags ->> $1"
      assert sql =~ "> $2"
      assert params == ["population", 1000]
    end
  end

  # ── Scope geometry (second spatial filter) ──────────────────────

  describe "scope_geometry" do
    test "adds a second spatial filter" do
      p =
        plan(%{
          spatial_filter: {:bbox, 40.0, -74.0, 41.0, -73.0},
          scope_geometry: {:around, 40.5, -73.5, 500.0}
        })

      {sql, params, _} = Where.build_where(p, @default_schema)

      assert sql =~ "ST_MakeEnvelope"
      assert sql =~ "ST_DWithin"
      # Both spatial clauses ANDed
      assert length(String.split(sql, " AND ")) == 2
      # bbox params then around params
      assert params == [-74.0, 40.0, -73.0, 41.0, -73.5, 40.5, 500.0]
    end
  end
end
