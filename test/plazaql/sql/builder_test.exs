defmodule PlazaQL.SQL.BuilderTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Plan
  alias PlazaQL.Plan.OutputOptions
  alias PlazaQL.Schema
  alias PlazaQL.SQL.Builder

  defp normalize(sql) do
    sql
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp default_schema(), do: Schema.new()

  defp plan(overrides \\ %{}) do
    struct!(%Plan{element_types: [:node]}, overrides)
  end

  # ── Basic output modes ───────────────────────────────────────────

  describe "full output mode" do
    test "builds SELECT with id, tags, geom, __type__" do
      {sql, params, _idx} = Builder.build_select(plan(), :node, default_schema())

      assert normalize(sql) ==
               normalize("SELECT osm_id, tags, geom, 'node' AS __type__ FROM osm_nodes")

      assert params == []
    end

    test "uses correct table for way" do
      {sql, _params, _idx} = Builder.build_select(plan(), :way, default_schema())
      assert sql =~ "FROM osm_ways"
      assert sql =~ "'way' AS __type__"
    end

    test "uses correct table for relation" do
      {sql, _params, _idx} = Builder.build_select(plan(), :relation, default_schema())
      assert sql =~ "FROM osm_relations"
      assert sql =~ "'relation' AS __type__"
    end
  end

  describe "ids output mode" do
    test "selects only id and __type__" do
      p = plan(%{output_mode: :ids})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert normalize(sql) ==
               normalize("SELECT osm_id, 'node' AS __type__ FROM osm_nodes")

      assert params == []
    end
  end

  describe "skel output mode" do
    test "selects id, geom, and __type__" do
      p = plan(%{output_mode: :skel})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert normalize(sql) ==
               normalize("SELECT osm_id, geom, 'node' AS __type__ FROM osm_nodes")

      assert params == []
    end
  end

  describe "tags output mode" do
    test "selects id, tags, and __type__" do
      p = plan(%{output_mode: :tags})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert normalize(sql) ==
               normalize("SELECT osm_id, tags, 'node' AS __type__ FROM osm_nodes")

      assert params == []
    end
  end

  describe "count output mode" do
    test "selects COUNT(*) and __type__" do
      p = plan(%{output_mode: :count})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert normalize(sql) ==
               normalize("SELECT COUNT(*) AS cnt, 'node' AS __type__ FROM osm_nodes")

      assert params == []
    end

    test "grouped count includes group_key" do
      group = {:tag_access, "amenity", nil}
      p = plan(%{output_mode: :count, group_by: group})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "tags ->> $1 AS group_key"
      assert sql =~ "COUNT(*) AS cnt"
      assert sql =~ "GROUP BY tags ->> $2"
      assert params == ["amenity", "amenity"]
    end
  end

  # ── Geometry transforms ──────────────────────────────────────────

  describe "geometry transforms" do
    test "simplify wraps geometry column" do
      opts = %OutputOptions{simplify: 100.0}
      p = plan(%{output_options: opts})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ST_SimplifyPreserveTopology(geom, $1)"
      assert_in_delta hd(params), 100.0 / 111_320.0, 1.0e-10
    end

    test "buffer wraps geometry column" do
      opts = %OutputOptions{buffer: 500.0}
      p = plan(%{output_options: opts})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ST_Buffer(geom::geography, $1)::geometry"
      assert_in_delta hd(params), 500.0, 1.0e-10
    end

    test "centroid wraps geometry column" do
      opts = %OutputOptions{centroid: true}
      p = plan(%{output_options: opts})
      {sql, _params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ST_Centroid(geom)"
    end

    test "combined transforms apply in order: simplify → buffer → centroid" do
      opts = %OutputOptions{simplify: 50.0, buffer: 100.0, centroid: true}
      p = plan(%{output_options: opts})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~
               "ST_Centroid(ST_Buffer(ST_SimplifyPreserveTopology(geom, $1)::geography, $2)::geometry)"

      assert length(params) == 2
    end

    test "geometry: false omits geometry column" do
      opts = %OutputOptions{geometry: false}
      p = plan(%{output_options: opts})
      {sql, _params, _idx} = Builder.build_select(p, :node, default_schema())

      assert normalize(sql) ==
               normalize("SELECT osm_id, tags, 'node' AS __type__ FROM osm_nodes")
    end
  end

  # ── Computed columns ─────────────────────────────────────────────

  describe "computed columns" do
    test "distance computed column" do
      computed = [{:distance_m, {:geom_func, :distance, {40.0, -74.0}, nil}}]
      p = plan(%{computed_columns: computed})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "AS distance_m"
      assert sql =~ "ST_Distance"
      assert params == [-74.0, 40.0]
    end

    test "area computed column" do
      computed = [{:area_m2, {:geom_func, :area, nil}}]
      p = plan(%{computed_columns: computed})
      {sql, _params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ST_Area(geom::geography) AS area_m2"
    end

    test "length computed column" do
      computed = [{:length_m, {:geom_func, :length, nil}}]
      p = plan(%{computed_columns: computed})
      {sql, _params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ST_Length(geom::geography) AS length_m"
    end

    test "elevation computed column" do
      schema = Schema.new(elevation_table: "elevation_raster")
      computed = [{:elevation_m, {:geom_func, :elevation, nil}}]
      p = plan(%{computed_columns: computed})
      {sql, _params, _idx} = Builder.build_select(p, :node, schema)

      assert sql =~ "AS elevation_m"
      assert sql =~ "ST_Value"
      assert sql =~ "elevation_raster"
    end
  end

  # ── Sort expressions ─────────────────────────────────────────────

  describe "sort expressions" do
    test "sort_expr with ascending" do
      sort = {{:tag_access, "name", nil}, :asc}
      p = plan(%{sort_expr: sort})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ORDER BY tags ->> $1 ASC"
      assert params == ["name"]
    end

    test "sort_expr with descending" do
      sort = {{:number, 1, nil}, :desc}
      p = plan(%{sort_expr: sort})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ORDER BY $1 DESC"
      assert params == [1]
    end

    test "output_options sort :distance" do
      opts = %OutputOptions{sort: :distance}
      p = plan(%{output_options: opts})
      {sql, _params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ORDER BY distance_m ASC"
    end

    test "output_options sort :name" do
      opts = %OutputOptions{sort: :name}
      p = plan(%{output_options: opts})
      {sql, _params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ORDER BY tags->>'name' ASC"
    end

    test "output_options sort :osm_id" do
      opts = %OutputOptions{sort: :osm_id}
      p = plan(%{output_options: opts})
      {sql, _params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ORDER BY osm_id ASC"
    end

    test "output_options sort :qt requires tile_id" do
      schema =
        Schema.new(
          tile_id_column: "tile_id",
          extensions: [h3: true]
        )

      opts = %OutputOptions{sort: :qt}
      p = plan(%{output_options: opts})
      {sql, _params, _idx} = Builder.build_select(p, :node, schema)

      assert sql =~ "ORDER BY tile_id ASC"
    end

    test "sort_expr takes precedence over output_options sort" do
      sort = {{:tag_access, "name", nil}, :asc}
      opts = %OutputOptions{sort: :distance}
      p = plan(%{sort_expr: sort, output_options: opts})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "ORDER BY tags ->> $1 ASC"
      assert params == ["name"]
      refute sql =~ "distance_m"
    end
  end

  # ── LIMIT and OFFSET ────────────────────────────────────────────

  describe "LIMIT and OFFSET" do
    test "LIMIT adds parameterized clause" do
      p = plan(%{limit: 100})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "LIMIT $1"
      assert params == [100]
    end

    test "OFFSET adds parameterized clause" do
      p = plan(%{offset: 50})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "OFFSET $1"
      assert params == [50]
    end

    test "LIMIT and OFFSET together" do
      p = plan(%{limit: 10, offset: 20})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "LIMIT $1"
      assert sql =~ "OFFSET $2"
      assert params == [10, 20]
    end
  end

  # ── DISTINCT ─────────────────────────────────────────────────────

  describe "DISTINCT" do
    test "adds DISTINCT keyword" do
      p = plan(%{distinct: true})
      {sql, _params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "SELECT DISTINCT"
    end

    test "omits DISTINCT when false" do
      p = plan(%{distinct: false})
      {sql, _params, _idx} = Builder.build_select(p, :node, default_schema())

      refute sql =~ "DISTINCT"
    end
  end

  # ── Aggregation ──────────────────────────────────────────────────

  describe "aggregation" do
    test "sum aggregation" do
      agg_expr = {:coerce_func, :number, {:tag_access, "population", nil}, nil}
      p = plan(%{output_mode: :sum, aggregate_expr: agg_expr})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "SUM("
      assert sql =~ "::float AS value"
      assert sql =~ "'node' AS __type__"
      assert params == ["population"]
    end

    test "min aggregation" do
      agg_expr = {:coerce_func, :number, {:tag_access, "height", nil}, nil}
      p = plan(%{output_mode: :min, aggregate_expr: agg_expr})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "MIN("
      assert sql =~ "::float AS value"
      assert params == ["height"]
    end

    test "max aggregation" do
      agg_expr = {:coerce_func, :number, {:tag_access, "height", nil}, nil}
      p = plan(%{output_mode: :max, aggregate_expr: agg_expr})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "MAX("
      assert sql =~ "::float AS value"
      assert params == ["height"]
    end

    test "avg aggregation includes count" do
      agg_expr = {:coerce_func, :number, {:tag_access, "speed", nil}, nil}
      p = plan(%{output_mode: :avg, aggregate_expr: agg_expr})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "AVG("
      assert sql =~ "::float AS avg_val"
      assert sql =~ "COUNT(*) AS cnt"
      assert params == ["speed"]
    end

    test "grouped sum includes group_key" do
      agg_expr = {:coerce_func, :number, {:tag_access, "population", nil}, nil}
      group = {:tag_access, "admin_level", nil}
      p = plan(%{output_mode: :sum, aggregate_expr: agg_expr, group_by: group})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "AS group_key"
      assert sql =~ "SUM("
      assert sql =~ "GROUP BY"
      assert "population" in params
      assert "admin_level" in params
    end

    test "grouped avg includes group_key, avg_val, and cnt" do
      agg_expr = {:coerce_func, :number, {:tag_access, "speed", nil}, nil}
      group = {:tag_access, "highway", nil}
      p = plan(%{output_mode: :avg, aggregate_expr: agg_expr, group_by: group})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "AS group_key"
      assert sql =~ "AVG("
      assert sql =~ "avg_val"
      assert sql =~ "COUNT(*) AS cnt"
      assert sql =~ "GROUP BY"
      assert "speed" in params
      assert "highway" in params
    end
  end

  # ── Custom schema ────────────────────────────────────────────────

  describe "custom schema" do
    test "uses custom table and column names" do
      schema =
        Schema.new(
          node_table: "custom_nodes",
          id_column: "entity_id",
          tags_column: "properties",
          geometry_column: "shape"
        )

      {sql, _params, _idx} = Builder.build_select(plan(), :node, schema)

      assert sql =~ "entity_id"
      assert sql =~ "properties"
      assert sql =~ "shape"
      assert sql =~ "FROM custom_nodes"
    end
  end

  # ── Boundary element type ───────────────────────────────────────

  describe "boundary element type" do
    test "uses relation table" do
      p = plan(%{element_types: [:boundary]})
      {sql, _params, _idx} = Builder.build_select(p, :boundary, default_schema())

      assert sql =~ "FROM osm_relations"
      assert sql =~ "'boundary' AS __type__"
    end
  end

  # ── Parameter index threading ───────────────────────────────────

  describe "parameter index threading" do
    test "starting at custom index" do
      p = plan(%{limit: 10})
      {sql, params, next_idx} = Builder.build_select(p, :node, default_schema(), 5)

      assert sql =~ "LIMIT $5"
      assert params == [10]
      assert next_idx == 6
    end

    test "returns correct next_idx with multiple parameterized clauses" do
      p = plan(%{limit: 10, offset: 20})
      {_sql, params, next_idx} = Builder.build_select(p, :node, default_schema(), 1)

      assert params == [10, 20]
      assert next_idx == 3
    end
  end

  # ── WHERE integration ───────────────────────────────────────────

  describe "WHERE clause integration" do
    test "includes WHERE from tag filters" do
      p = plan(%{tag_filters: [{:eq, "amenity", "cafe"}]})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "WHERE"
      assert sql =~ "tags"
      assert "amenity" in params
      assert "cafe" in params
    end

    test "includes spatial filter in WHERE" do
      p = plan(%{spatial_filter: {:bbox, 40.0, -74.0, 41.0, -73.0}})
      {sql, params, _idx} = Builder.build_select(p, :node, default_schema())

      assert sql =~ "WHERE"
      assert sql =~ "ST_MakeEnvelope"
      assert length(params) == 4
    end
  end
end
