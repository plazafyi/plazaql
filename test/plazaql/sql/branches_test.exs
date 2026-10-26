defmodule PlazaQL.SQL.BranchesTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Plan
  alias PlazaQL.Plan.OutputOptions
  alias PlazaQL.Query
  alias PlazaQL.Schema
  alias PlazaQL.SQL

  @schema Schema.new(
            columns: [tile_id: "tile_id", partition_tile_id: "partition_tile_id"],
            extensions: [h3: true, partition_pruning: true],
            partitioned: [:node, :way],
            full_columns: [node: ["version"], relation: ["rel_type"]],
            sources: [
              features: [
                table: "dataset_features",
                type: "feature",
                columns: [id: "id", filter_tags: "properties"],
                keys: ["id", "dataset_id"],
                full_columns: ["properties"],
                typed_values: true,
                sparse_tile_id: true
              ]
            ]
          )

  defp branches(plan) do
    {:ok, branches} = SQL.branches(plan, @schema)
    Map.new(branches, fn {name, %Query{sql: sql, params: params}} -> {name, {sql, params}} end)
  end

  defp sql(plan, branch), do: elem(Map.fetch!(branches(plan), branch), 0)
  defp params(plan, branch), do: elem(Map.fetch!(branches(plan), branch), 1)

  describe "branches/2" do
    test "one query per element type, then per source, in rank order" do
      plan = %Plan{element_types: [:node, :way], sources: ["features"]}

      assert {:ok, [{:node, %Query{}}, {:way, %Query{}}, {"features", %Query{}}]} =
               SQL.branches(plan, @schema)
    end

    test "each branch numbers its own parameters from $1" do
      plan = %Plan{element_types: [:node, :way], tag_filters: [{:exists, "amenity"}]}

      for {_type, {sql, params}} <- branches(plan) do
        assert sql =~ "tags ? $1"
        assert params == ["amenity"]
      end
    end

    test "computations and set operations are not compiled per branch" do
      assert {:error, %PlazaQL.NotCompilable{reason: :route}} =
               SQL.branches(%Plan{kind: :computation, computation: {:route, %{}}}, @schema)

      assert {:error, %PlazaQL.NotCompilable{reason: :set_ops}} =
               SQL.branches(%Plan{set_ops: [union: %Plan{}]}, @schema)
    end

    test "an unknown source is an argument error" do
      assert_raise ArgumentError, ~r/unknown source/, fn ->
        SQL.branches(%Plan{element_types: [], sources: ["nope"]}, @schema)
      end
    end
  end

  describe "full output" do
    test "selects the table's extra columns" do
      plan = %Plan{element_types: [:node, :way, :relation]}

      assert sql(plan, :node) =~ "SELECT osm_id, tags, geom, version, 'node' AS __type__"
      assert sql(plan, :way) =~ "SELECT osm_id, tags, geom, 'way' AS __type__"
      assert sql(plan, :relation) =~ "SELECT osm_id, tags, geom, rel_type, 'relation' AS __type__"
    end

    test "a source selects its keys, tags, geometry and extra columns, ordered by its keys" do
      plan = %Plan{element_types: [], sources: ["features"]}

      assert sql(plan, "features") ==
               "SELECT id, dataset_id, tags, geom, properties, 'feature' AS __type__ " <>
                 "FROM dataset_features ORDER BY id ASC, dataset_id ASC"
    end
  end

  describe "keys output" do
    test "selects the key and the partition key of partitioned tables" do
      plan = %Plan{element_types: [:node, :relation], output_mode: :keys}

      assert sql(plan, :node) =~ "SELECT osm_id, partition_tile_id, 'node' AS __type__"
      assert sql(plan, :relation) =~ "SELECT osm_id, 'relation' AS __type__"
    end
  end

  describe "sources" do
    test "tag filters read the filter column" do
      plan = %Plan{element_types: [], sources: ["features"], tag_filters: [{:exists, "kind"}]}
      assert sql(plan, "features") =~ "WHERE properties ? $1"
    end

    test "typed values: equality matches the string or the value it spells" do
      plan = %Plan{
        element_types: [],
        sources: ["features"],
        tag_filters: [{:eq, "floors", "5"}, {:eq, "open", "true"}, {:eq, "ref", "05"}]
      }

      assert sql(plan, "features") =~
               "WHERE (properties @> $1::jsonb OR properties @> $2::jsonb) AND " <>
                 "(properties @> $3::jsonb OR properties @> $4::jsonb) AND (properties @> $5::jsonb)"

      assert params(plan, "features") == [
               %{"floors" => "5"},
               %{"floors" => 5},
               %{"open" => "true"},
               %{"open" => true},
               %{"ref" => "05"}
             ]
    end

    test "typed values: a float matches only when it prints back to the string" do
      plan = %Plan{
        element_types: [],
        sources: ["features"],
        tag_filters: [{:eq, "h", "2.5"}, {:eq, "w", "2.50"}]
      }

      assert params(plan, "features") == [%{"h" => "2.5"}, %{"h" => 2.5}, %{"w" => "2.50"}]
    end

    test "sparse tile ids keep NULL-tile rows as H3 candidates" do
      plan = %Plan{
        element_types: [],
        sources: ["features"],
        caller_context: %{h3_tiles: ["872a1072bffffff"]}
      }

      assert sql(plan, "features") =~
               "WHERE (tile_id IS NULL OR (tile_id <@ $1::h3index OR tile_id @> $1::h3index))"
    end

    test "an H3 cell filter matches NULL-tile rows by geometry" do
      plan = %Plan{element_types: [], sources: ["features"], spatial_filter: {:h3, "872a"}}

      assert sql(plan, "features") =~
               "(tile_id <@ $1::h3index OR tile_id @> $1::h3index OR (tile_id IS NULL AND " <>
                 "ST_Intersects(geom, h3_cell_to_boundary_geometry($1::h3index))))"
    end

    test "osm ids, metadata and partitions don't apply to sources" do
      plan = %Plan{
        element_types: [:node],
        sources: ["features"],
        osm_ids: [1, 2],
        metadata_filters: [{:version, 3}],
        caller_context: %{partitions: [10, 11]}
      }

      assert sql(plan, :node) =~
               "WHERE osm_id = ANY($1) AND version = $2 AND partition_tile_id = ANY($3::bigint[])"

      refute sql(plan, "features") =~ "WHERE"
    end

    test "custom clauses can target one branch" do
      plan = %Plan{
        element_types: [:node],
        sources: ["features"],
        tag_filters: [{:exists, "name"}],
        custom_clauses: [{"features", "dataset_id = ANY($1)", [["d1"]]}, {"TRUE", []}]
      }

      assert sql(plan, "features") =~ "WHERE properties ? $1 AND dataset_id = ANY($2) AND TRUE"
      assert params(plan, "features") == ["name", ["d1"]]
      assert sql(plan, :node) =~ "WHERE tags ? $1 AND TRUE ORDER"
    end

    test "type() is the source's type" do
      type_is = {:bin_op, :eq, {:prop_access, :type, nil}, {:string, "feature", nil}, nil}
      plan = %Plan{element_types: [:node], sources: ["features"], filter_exprs: [type_is]}

      assert params(plan, :node) == ["node", "feature"]
      assert params(plan, "features") == ["feature", "feature"]
    end
  end

  describe "type()" do
    test "is bound per branch, boundary rows being relations" do
      type_expr = {:prop_access, :type, nil}

      plan = %Plan{
        element_types: [:way, :boundary],
        output_mode: :count,
        group_by: type_expr
      }

      assert params(plan, :way) == ["way"]
      assert params(plan, :boundary) == ["relation"]
    end
  end

  describe "boundary branch" do
    test "only the boundary branch requires the boundary tag" do
      plan = %Plan{element_types: [:relation, :boundary]}

      refute sql(plan, :relation) =~ "'boundary'"
      assert sql(plan, :boundary) =~ "FROM osm_relations WHERE tags ? 'boundary'"
      assert sql(plan, :boundary) =~ "'boundary' AS __type__"
    end
  end

  describe "partitions" do
    test "per-type partitions apply to that type only, never to unpartitioned tables" do
      plan = %Plan{
        element_types: [:node, :way, :relation],
        caller_context: %{partitions: %{node: [1], way: [1, 2]}}
      }

      assert params(plan, :node) == [[1]]
      assert params(plan, :way) == [[1, 2]]
      assert params(plan, :relation) == []
    end
  end

  describe "H3 tile prefilter" do
    test "is skipped above the schema's tile limit" do
      tiles = for i <- 1..21, do: "cell#{i}"
      plan = %Plan{element_types: [:node], caller_context: %{h3_tiles: tiles}}

      refute sql(plan, :node) =~ "h3index"
    end
  end

  describe "keyset seek" do
    defp seek_sql(plan, branch) do
      [_, where] = Regex.run(~r/WHERE (.*) ORDER BY/, sql(plan, branch))
      where
    end

    test "unsorted: earlier branches are done, the cursor's branch resumes after its key" do
      plan = %Plan{element_types: [:node, :way, :relation], seek: {nil, 1, 42}}

      assert seek_sql(plan, :node) == "FALSE"
      assert seek_sql(plan, :way) == "osm_id > $1"
      assert params(plan, :way) == [42]
      refute sql(plan, :relation) =~ "WHERE"
    end

    test "sorted ascending: (sort value, rank, keys) order" do
      sort = {{:tag_access, "name", nil}, :asc}
      plan = %Plan{element_types: [:node, :way, :relation], sort_expr: sort, seek: {"m", 1, 7}}

      assert seek_sql(plan, :node) == "(tags ->> $2 > $3 OR tags ->> $4 IS NULL)"

      assert seek_sql(plan, :way) ==
               "((tags ->> $2 > $3 OR tags ->> $4 IS NULL) OR (tags ->> $5 = $6 AND osm_id > $7))"

      assert params(plan, :way) == ["name", "name", "m", "name", "name", "m", 7, "name"]

      assert seek_sql(plan, :relation) ==
               "((tags ->> $2 > $3 OR tags ->> $4 IS NULL) OR tags ->> $5 = $6)"
    end

    test "sorted ascending after a null sort value: only later nulls remain" do
      sort = {{:tag_access, "name", nil}, :asc}
      plan = %Plan{element_types: [:node], sort_expr: sort, seek: {nil, 0, 7}}

      assert seek_sql(plan, :node) == "(FALSE OR (tags ->> $2 IS NULL AND osm_id > $3))"
    end

    test "sorted descending: nulls come first" do
      sort = {{:tag_access, "name", nil}, :desc}

      after_null = %Plan{element_types: [:node], sort_expr: sort, seek: {nil, 1, 7}}
      assert seek_sql(after_null, :node) == "tags ->> $2 IS NOT NULL"

      after_value = %Plan{element_types: [:node], sort_expr: sort, seek: {"m", 1, 7}}
      assert seek_sql(after_value, :node) == "tags ->> $2 < $3"
    end

    test "a multi-column key compares as a row" do
      plan = %Plan{element_types: [], sources: ["features"], seek: {nil, 0, {"f1", "uuid"}}}

      assert seek_sql(plan, "features") == "(id, dataset_id) > ($1, $2)"
      assert params(plan, "features") == ["f1", "uuid"]
    end

    test "a source ranks after the element types" do
      plan = %Plan{element_types: [:node], sources: ["features"], seek: {nil, 0, 5}}

      assert seek_sql(plan, :node) == "osm_id > $1"
      refute sql(plan, "features") =~ "WHERE"
    end

    test "a rank before every branch (a split plan) keeps all of them" do
      plan = %Plan{element_types: [], sources: ["features"], seek: {nil, -2, 5}}
      refute sql(plan, "features") =~ "WHERE"
    end
  end

  describe "sort by qt" do
    test "orders by the cell, reports its text form" do
      plan = %Plan{element_types: [:way], output_options: %OutputOptions{sort: :qt}}

      assert sql(plan, :way) =~ "tile_id::text AS sort_key"
      assert sql(plan, :way) =~ "ORDER BY tile_id ASC, osm_id ASC"
    end
  end

  describe "include distance" do
    test "adds distance_m from the around point" do
      plan = %Plan{
        element_types: [:node],
        spatial_filter: {:around, 48.0, 2.0, 100},
        output_options: %OutputOptions{include: MapSet.new([:distance])}
      }

      assert sql(plan, :node) =~
               "ST_Distance(ST_Centroid(geom)::geography, ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography) AS distance_m"

      assert [2.0, 48.0 | _] = params(plan, :node)
    end

    test "keeps a distance the plan already computes" do
      plan = %Plan{
        element_types: [:node],
        spatial_filter: {:around, 48.0, 2.0, 100},
        computed_columns: [distance_m: {:geom_func, :distance, {1.0, 1.0}, nil}],
        output_options: %OutputOptions{include: MapSet.new([:distance])}
      }

      assert [1.0, 1.0 | _] = params(plan, :node)
    end
  end

  describe "aggregates" do
    test "group by position, not by a re-parameterized expression" do
      plan = %Plan{
        element_types: [:node],
        output_mode: :sum,
        group_by: {:tag_access, "kind", nil},
        aggregate_expr: {:geom_func, :length, nil}
      }

      assert sql(plan, :node) ==
               "SELECT tags ->> $1 AS group_key, SUM(ST_Length(geom::geography)) AS value, " <>
                 "'node' AS __type__ FROM osm_nodes GROUP BY 1"
    end

    test "aggregate queries are not ordered" do
      plan = %Plan{element_types: [:node], output_mode: :count}
      refute sql(plan, :node) =~ "ORDER BY"
    end
  end
end
