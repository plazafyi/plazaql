defmodule PlazaQL.SchemaTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Schema

  describe "default/0" do
    test "returns default table names" do
      schema = Schema.default()
      assert schema.tables.node == "osm_nodes"
      assert schema.tables.way == "osm_ways"
      assert schema.tables.relation == "osm_relations"
      assert schema.tables.admin_boundaries == nil
    end

    test "returns default column names" do
      schema = Schema.default()
      assert schema.columns.id == "osm_id"
      assert schema.columns.geometry == "geom"
      assert schema.columns.tags == "tags"
      assert schema.columns.tile_id == nil
      assert schema.columns.partition_tile_id == nil
    end

    test "returns default srid, limits, extensions, and elevation_table" do
      schema = Schema.default()
      assert schema.srid == 4326
      assert schema.limits.max_osm_ids == 10_000
      assert schema.extensions.h3 == false
      assert schema.extensions.partition_pruning == false
      assert schema.elevation_table == nil
    end
  end

  describe "new/1 with flat keyword shortcuts" do
    test "overrides individual table names" do
      schema = Schema.new(node_table: "my_nodes", way_table: "my_ways")
      assert schema.tables.node == "my_nodes"
      assert schema.tables.way == "my_ways"
      # Other defaults preserved
      assert schema.tables.relation == "osm_relations"
    end

    test "overrides individual column names" do
      schema = Schema.new(id_column: "gid", geometry_column: "the_geom")
      assert schema.columns.id == "gid"
      assert schema.columns.geometry == "the_geom"
      assert schema.columns.tags == "tags"
    end
  end

  describe "new/1 with nested keywords" do
    test "overrides tables via nested keyword" do
      schema = Schema.new(tables: [node: "custom_nodes"])
      assert schema.tables.node == "custom_nodes"
      assert schema.tables.way == "osm_ways"
    end

    test "overrides columns via nested keyword" do
      schema = Schema.new(columns: [geometry: "shape", tile_id: "h3_tile"])
      assert schema.columns.geometry == "shape"
      assert schema.columns.tile_id == "h3_tile"
      assert schema.columns.id == "osm_id"
    end

    test "overrides extensions via nested keyword" do
      schema =
        Schema.new(
          extensions: [h3: true],
          columns: [tile_id: "tile_id"]
        )

      assert schema.extensions.h3 == true
      assert schema.extensions.partition_pruning == false
    end

    test "overrides srid and elevation_table" do
      schema = Schema.new(srid: 3857, elevation_table: "dem_tiles")
      assert schema.srid == 3857
      assert schema.elevation_table == "dem_tiles"
    end
  end

  describe "merge behavior" do
    test "partial table overrides keep other table defaults" do
      schema = Schema.new(tables: [relation: "rels"])
      assert schema.tables.node == "osm_nodes"
      assert schema.tables.way == "osm_ways"
      assert schema.tables.relation == "rels"
    end

    test "partial column overrides keep other column defaults" do
      schema = Schema.new(columns: [tags: "properties"])
      assert schema.columns.id == "osm_id"
      assert schema.columns.geometry == "geom"
      assert schema.columns.tags == "properties"
    end

    test "flat and nested can be combined" do
      schema = Schema.new(node_table: "flat_nodes", tables: [way: "nested_ways"])
      assert schema.tables.node == "flat_nodes"
      assert schema.tables.way == "nested_ways"
      assert schema.tables.relation == "osm_relations"
    end
  end

  describe "identifier validation" do
    test "rejects identifiers with special characters" do
      assert_raise ArgumentError, ~r/invalid identifier/, fn ->
        Schema.new(node_table: "my-table")
      end
    end

    test "rejects identifiers starting with a number" do
      assert_raise ArgumentError, ~r/invalid identifier/, fn ->
        Schema.new(node_table: "1table")
      end
    end

    test "rejects SQL injection attempts" do
      assert_raise ArgumentError, ~r/invalid identifier/, fn ->
        Schema.new(node_table: "nodes; DROP TABLE users")
      end
    end

    test "rejects identifiers with uppercase letters" do
      assert_raise ArgumentError, ~r/invalid identifier/, fn ->
        Schema.new(id_column: "OsmId")
      end
    end

    test "rejects empty string identifiers" do
      assert_raise ArgumentError, ~r/invalid identifier/, fn ->
        Schema.new(node_table: "")
      end
    end

    test "accepts valid snake_case identifiers" do
      schema = Schema.new(node_table: "osm_planet_nodes", id_column: "entity_id")
      assert schema.tables.node == "osm_planet_nodes"
      assert schema.columns.id == "entity_id"
    end

    test "validates elevation_table identifier" do
      assert_raise ArgumentError, ~r/invalid identifier/, fn ->
        Schema.new(elevation_table: "DROP TABLE")
      end
    end

    test "nil values are not validated as identifiers" do
      # Should not raise — nil admin_boundaries and nil tile columns are fine
      schema = Schema.new()
      assert schema.tables.admin_boundaries == nil
    end
  end

  describe "extension/column consistency validation" do
    test "raises when h3 is true but tile_id is nil" do
      assert_raise ArgumentError, ~r/tile_id must be set/, fn ->
        Schema.new(extensions: [h3: true])
      end
    end

    test "accepts h3 when tile_id is provided" do
      schema =
        Schema.new(
          extensions: [h3: true],
          tile_id_column: "tile_id"
        )

      assert schema.extensions.h3 == true
      assert schema.columns.tile_id == "tile_id"
    end

    test "raises when partition_pruning is true but partition_tile_id is nil" do
      assert_raise ArgumentError, ~r/partition_tile_id must be set/, fn ->
        Schema.new(extensions: [partition_pruning: true])
      end
    end

    test "accepts partition_pruning when partition_tile_id is provided" do
      schema =
        Schema.new(
          extensions: [partition_pruning: true],
          partition_tile_id_column: "part_tile"
        )

      assert schema.extensions.partition_pruning == true
      assert schema.columns.partition_tile_id == "part_tile"
    end
  end

  describe "unknown options" do
    test "raises on unknown top-level keys" do
      assert_raise ArgumentError, ~r/unknown schema option/, fn ->
        Schema.new(bogus: "value")
      end
    end
  end
end
