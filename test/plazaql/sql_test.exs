defmodule PlazaQL.SQLTest do
  use ExUnit.Case, async: true

  alias PlazaQL.NotCompilable
  alias PlazaQL.Plan
  alias PlazaQL.Query
  alias PlazaQL.Schema
  alias PlazaQL.SQL

  defp normalize(sql) do
    sql
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp default_schema(), do: Schema.new()

  defp plan(overrides \\ %{}) do
    struct!(%Plan{element_types: [:node]}, overrides)
  end

  # ── Single type, simple query ──────────────────────────────────

  describe "single element type" do
    test "simple query generates SELECT" do
      p = plan(%{tag_filters: [{:eq, "amenity", "cafe"}]})
      {:ok, %Query{sql: sql, params: params}} = SQL.to_sql(p, default_schema())

      assert sql =~ "SELECT"
      assert sql =~ "FROM osm_nodes"
      assert sql =~ "tags"
      assert "amenity" in params
      assert "cafe" in params
    end

    test "preserves plan in result" do
      p = plan()
      {:ok, %Query{plan: result_plan}} = SQL.to_sql(p, default_schema())
      assert result_plan == p
    end
  end

  # ── Multi-type UNION ALL ──────────────────────────────────────

  describe "multi-type UNION ALL" do
    test "generates UNION ALL for multiple element types" do
      p = plan(%{element_types: [:node, :way, :relation]})
      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())

      assert sql =~ "UNION ALL"
      assert sql =~ "osm_nodes"
      assert sql =~ "osm_ways"
      assert sql =~ "osm_relations"
    end

    test "two types produce one UNION ALL" do
      p = plan(%{element_types: [:node, :way]})
      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())

      # Should have exactly one UNION ALL
      parts = String.split(sql, "UNION ALL")
      assert length(parts) == 2
    end

    test "three types produce two UNION ALLs" do
      p = plan(%{element_types: [:node, :way, :relation]})
      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())

      parts = String.split(sql, "UNION ALL")
      assert length(parts) == 3
    end
  end

  # ── Multi-type with LIMIT ─────────────────────────────────────

  describe "multi-type with LIMIT" do
    test "per-branch limit is doubled, outer limit is original" do
      p = plan(%{element_types: [:node, :way], limit: 10})
      {:ok, %Query{sql: sql, params: params}} = SQL.to_sql(p, default_schema())

      assert sql =~ "UNION ALL"
      # Outer LIMIT should be the last thing
      assert String.ends_with?(String.trim(sql), "LIMIT $#{length(params)}")
      # The last param should be the original limit
      assert List.last(params) == 10
      # Per-branch limits should be 20 (limit * 2)
      assert 20 in params
    end

    test "single type with limit does not double" do
      p = plan(%{element_types: [:node], limit: 10})
      {:ok, %Query{sql: sql, params: params}} = SQL.to_sql(p, default_schema())

      refute sql =~ "UNION ALL"
      assert sql =~ "LIMIT"
      assert 10 in params
      refute 20 in params
    end
  end

  # ── Count single type ─────────────────────────────────────────

  describe "count single type" do
    test "generates COUNT(*)" do
      p = plan(%{output_mode: :count})
      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())

      assert normalize(sql) =~ "COUNT(*) AS cnt"
      assert sql =~ "FROM osm_nodes"
    end
  end

  # ── Count multi-type (aggregation wrapper) ─────────────────────

  describe "count multi-type" do
    test "wraps with SUM(cnt) aggregation" do
      p = plan(%{element_types: [:node, :way], output_mode: :count})
      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())

      assert sql =~ "SUM(cnt) AS total"
      assert sql =~ "UNION ALL"
      assert sql =~ "sub"
    end
  end

  # ── Sum/min/max ───────────────────────────────────────────────

  describe "sum/min/max multi-type" do
    test "sum wraps with SUM(value)" do
      p =
        plan(%{
          element_types: [:node, :way],
          output_mode: :sum,
          aggregate_expr: {:tag_access, "population", nil}
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      assert sql =~ "SUM(value) AS value"
      assert sql =~ "sub"
    end

    test "min wraps with MIN(value)" do
      p =
        plan(%{
          element_types: [:node, :way],
          output_mode: :min,
          aggregate_expr: {:tag_access, "ele", nil}
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      assert sql =~ "MIN(value) AS value"
    end

    test "max wraps with MAX(value)" do
      p =
        plan(%{
          element_types: [:node, :way],
          output_mode: :max,
          aggregate_expr: {:tag_access, "ele", nil}
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      assert sql =~ "MAX(value) AS value"
    end
  end

  # ── Avg (weighted) ────────────────────────────────────────────

  describe "avg multi-type (weighted)" do
    test "wraps with weighted average formula" do
      p =
        plan(%{
          element_types: [:node, :way],
          output_mode: :avg,
          aggregate_expr: {:tag_access, "height", nil}
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      assert sql =~ "SUM(avg_val * cnt)"
      assert sql =~ "NULLIF(SUM(cnt), 0)"
    end
  end

  # ── Grouped count ─────────────────────────────────────────────

  describe "grouped aggregation" do
    test "grouped count has outer GROUP BY" do
      p =
        plan(%{
          element_types: [:node, :way],
          output_mode: :count,
          group_by: {:tag_access, "amenity", nil}
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      assert sql =~ "group_key"
      assert sql =~ "GROUP BY group_key"
      assert sql =~ "SUM(cnt) AS total"
    end

    test "grouped avg has outer GROUP BY with weighted formula" do
      p =
        plan(%{
          element_types: [:node, :way],
          output_mode: :avg,
          aggregate_expr: {:tag_access, "height", nil},
          group_by: {:tag_access, "building", nil}
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      assert sql =~ "group_key"
      assert sql =~ "GROUP BY group_key"
      assert sql =~ "SUM(avg_val * cnt)"
    end
  end

  # ── Set operations ────────────────────────────────────────────

  describe "union set op" do
    test "generates CTE with UNION" do
      sub = plan(%{element_types: [:node], tag_filters: [{:eq, "cuisine", "italian"}]})

      p =
        plan(%{
          element_types: [:node],
          tag_filters: [{:eq, "amenity", "restaurant"}],
          set_ops: [{:union, sub}]
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      assert sql =~ "WITH"
      assert sql =~ "base AS"
      assert sql =~ "union_0 AS"
      assert sql =~ "SELECT * FROM base"
      assert sql =~ "UNION"
      assert sql =~ "SELECT * FROM union_0"
    end
  end

  describe "difference set op" do
    test "generates CTE with NOT EXISTS" do
      sub = plan(%{element_types: [:node], tag_filters: [{:eq, "access", "private"}]})

      p =
        plan(%{
          element_types: [:node],
          tag_filters: [{:eq, "amenity", "cafe"}],
          set_ops: [{:difference, sub}]
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      assert sql =~ "WITH"
      assert sql =~ "difference_0 AS"
      assert sql =~ "NOT EXISTS"
      assert sql =~ "osm_id"
      assert sql =~ "__type__"
    end
  end

  describe "intersection set op" do
    test "generates CTE with EXISTS" do
      sub = plan(%{element_types: [:node], tag_filters: [{:eq, "wheelchair", "yes"}]})

      p =
        plan(%{
          element_types: [:node],
          tag_filters: [{:eq, "amenity", "cafe"}],
          set_ops: [{:intersection, sub}]
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      assert sql =~ "WITH"
      assert sql =~ "intersection_0 AS"
      assert sql =~ "EXISTS"
      assert sql =~ "osm_id"
      assert sql =~ "__type__"
      # Should NOT have NOT EXISTS (that's difference)
      refute sql =~ "NOT EXISTS"
    end
  end

  describe "set op spatial inheritance" do
    test "sub-plan inherits parent spatial_filter when nil" do
      sub = plan(%{element_types: [:node], tag_filters: [{:eq, "cuisine", "sushi"}]})

      p =
        plan(%{
          element_types: [:node],
          tag_filters: [{:eq, "amenity", "restaurant"}],
          spatial_filter: {:bbox, 40.0, -74.0, 41.0, -73.0},
          set_ops: [{:union, sub}]
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      # Both base and sub should have spatial filter (ST_MakeEnvelope appears twice)
      count = length(String.split(sql, "ST_MakeEnvelope")) - 1
      assert count == 2
    end

    test "sub-plan keeps its own spatial_filter" do
      sub =
        plan(%{
          element_types: [:node],
          tag_filters: [{:eq, "cuisine", "sushi"}],
          spatial_filter: {:around, 35.6, 139.7, 500.0}
        })

      p =
        plan(%{
          element_types: [:node],
          tag_filters: [{:eq, "amenity", "restaurant"}],
          spatial_filter: {:bbox, 40.0, -74.0, 41.0, -73.0},
          set_ops: [{:union, sub}]
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())
      # Base has bbox, sub has around — both should be present
      assert sql =~ "ST_MakeEnvelope"
      assert sql =~ "ST_DWithin"
    end
  end

  # ── Computation returns error ─────────────────────────────────

  describe "computation plans" do
    test "returns NotCompilable error" do
      p = plan(%{kind: :computation, computation: {:route, %{}}})
      assert {:error, %NotCompilable{reason: :route}} = SQL.to_sql(p, default_schema())
    end

    test "includes plan in error" do
      p = plan(%{kind: :computation, computation: {:isochrone, %{}}})
      {:error, error} = SQL.to_sql(p, default_schema())
      assert error.plan == p
      assert error.reason == :isochrone
    end
  end

  # ── End-to-end from source ────────────────────────────────────

  describe "PlazaQL.query/1 end-to-end" do
    test "parses and generates SQL from source string" do
      {:ok, %Query{sql: sql, params: params}} =
        PlazaQL.query(~s|$$ = search(node, amenity: "cafe").limit(5);|)

      assert sql =~ "FROM osm_nodes"
      assert sql =~ "LIMIT"
      assert 5 in params
    end

    test "returns error for invalid syntax" do
      assert {:error, _} = PlazaQL.query("invalid!!!")
    end
  end

  # ── PlazaQL.to_sql/2 convenience ──────────────────────────────

  describe "PlazaQL.to_sql/2" do
    test "delegates to SQL module" do
      p = plan(%{tag_filters: [{:eq, "amenity", "cafe"}]})
      {:ok, %Query{sql: sql}} = PlazaQL.to_sql(p)
      assert sql =~ "FROM osm_nodes"
    end
  end

  # ── Custom schema ─────────────────────────────────────────────

  describe "custom schema" do
    test "uses custom table names" do
      schema =
        Schema.new(
          node_table: "custom_nodes",
          way_table: "custom_ways",
          relation_table: "custom_relations"
        )

      p = plan(%{element_types: [:node, :way, :relation]})
      {:ok, %Query{sql: sql}} = SQL.to_sql(p, schema)

      assert sql =~ "custom_nodes"
      assert sql =~ "custom_ways"
      assert sql =~ "custom_relations"
      refute sql =~ "osm_nodes"
    end

    test "uses custom column names" do
      schema = Schema.new(id_column: "entity_id", tags_column: "properties")

      p = plan(%{output_mode: :ids})
      {:ok, %Query{sql: sql}} = SQL.to_sql(p, schema)

      assert sql =~ "entity_id"
      refute sql =~ "osm_id"
    end
  end

  # ── Spatial + tag filters combined ────────────────────────────

  describe "spatial + tag filters" do
    test "generates WHERE with both spatial and tag conditions" do
      p =
        plan(%{
          tag_filters: [{:eq, "amenity", "cafe"}],
          spatial_filter: {:bbox, 40.0, -74.0, 41.0, -73.0}
        })

      {:ok, %Query{sql: sql, params: params}} = SQL.to_sql(p, default_schema())

      assert sql =~ "WHERE"
      assert sql =~ "ST_MakeEnvelope"
      assert sql =~ "tags"
      assert params != []
    end

    test "around spatial filter in query" do
      p =
        plan(%{
          tag_filters: [{:eq, "amenity", "cafe"}],
          spatial_filter: {:around, 40.7, -74.0, 1000.0}
        })

      {:ok, %Query{sql: sql}} = SQL.to_sql(p, default_schema())

      assert sql =~ "ST_DWithin"
      assert sql =~ "tags"
    end
  end

  # ── Default schema ────────────────────────────────────────────

  describe "default schema" do
    test "uses default schema when none provided" do
      p = plan()
      {:ok, %Query{sql: sql}} = SQL.to_sql(p)
      assert sql =~ "osm_nodes"
    end
  end
end
