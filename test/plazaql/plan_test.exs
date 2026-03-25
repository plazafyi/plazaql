defmodule PlazaQL.PlanTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Plan
  alias PlazaQL.Plan.OutputOptions

  describe "default struct" do
    test "has correct default field values" do
      plan = %Plan{}

      assert plan.element_types == [:node, :way, :relation]
      assert plan.tag_filters == []
      assert plan.spatial_filter == nil
      assert plan.scope_geometry == nil
      assert plan.osm_ids == nil
      assert plan.metadata_filters == []
      assert plan.filter_exprs == []
      assert plan.output_mode == :full
      assert plan.output_options == nil
      assert plan.computed_columns == []
      assert plan.distinct == false
      assert plan.limit == nil
      assert plan.offset == nil
      assert plan.sort_expr == nil
      assert plan.aggregate_expr == nil
      assert plan.group_by == nil
      assert plan.set_ops == []
      assert plan.sources == nil
      assert plan.kind == :query
      assert plan.computation == nil
      assert plan.caller_context == %{}
      assert plan.custom_clauses == []
    end
  end

  describe "struct creation with overrides" do
    test "accepts element_types override" do
      plan = %Plan{element_types: [:way]}
      assert plan.element_types == [:way]
    end

    test "accepts tag_filters" do
      plan = %Plan{tag_filters: [{:eq, "highway", "residential"}]}
      assert plan.tag_filters == [{:eq, "highway", "residential"}]
    end

    test "accepts spatial_filter" do
      plan = %Plan{spatial_filter: {:bbox, 40.0, -74.0, 41.0, -73.0}}
      assert plan.spatial_filter == {:bbox, 40.0, -74.0, 41.0, -73.0}
    end

    test "accepts output_options struct" do
      opts = %OutputOptions{simplify: 10.0, centroid: true}
      plan = %Plan{output_options: opts}
      assert plan.output_options.simplify == 10.0
      assert plan.output_options.centroid == true
    end

    test "accepts computation" do
      plan = %Plan{
        kind: :computation,
        computation: {:route, %{origin: {40.7, -74.0}, destination: {40.8, -73.9}}}
      }

      assert plan.kind == :computation
      assert {:route, %{origin: {40.7, -74.0}}} = plan.computation
    end

    test "accepts limit, offset, and distinct" do
      plan = %Plan{limit: 100, offset: 50, distinct: true}
      assert plan.limit == 100
      assert plan.offset == 50
      assert plan.distinct == true
    end

    test "accepts set_ops" do
      inner = %Plan{element_types: [:node]}
      plan = %Plan{set_ops: [{:union, inner}]}
      assert [{:union, %Plan{element_types: [:node]}}] = plan.set_ops
    end

    test "accepts caller_context" do
      plan = %Plan{caller_context: %{resolved_tiles: ["abc"], partitions: [1, 2]}}
      assert plan.caller_context.resolved_tiles == ["abc"]
    end

    test "accepts custom_clauses" do
      plan = %Plan{custom_clauses: [{"ST_Area(geom) > $1", [1000.0]}]}
      assert [{"ST_Area(geom) > $1", [1000.0]}] = plan.custom_clauses
    end
  end

  describe "computation types" do
    @computation_types [
      :route,
      :isochrone,
      :matrix,
      :geocode,
      :reverse_geocode,
      :map_match,
      :optimize,
      :ev_route,
      :elevation_lookup,
      :elevation_profile,
      :search,
      :autocomplete,
      :nearest
    ]

    test "all computation types can be used in a plan" do
      for type <- @computation_types do
        plan = %Plan{kind: :computation, computation: {type, %{}}}
        assert {^type, %{}} = plan.computation
      end
    end
  end

  describe "OutputOptions" do
    test "has correct defaults" do
      opts = %OutputOptions{}

      assert opts.simplify == nil
      assert opts.buffer == nil
      assert opts.precision == nil
      assert opts.centroid == false
      assert opts.geometry == true
      assert opts.fields == :all
      assert opts.include == MapSet.new()
      assert opts.sort == nil
    end

    test "accepts overrides" do
      opts = %OutputOptions{
        simplify: 5.0,
        buffer: 100.0,
        precision: 6,
        centroid: true,
        geometry: false,
        fields: ["name", "highway"],
        include: MapSet.new([:bbox, :center]),
        sort: :distance
      }

      assert opts.simplify == 5.0
      assert opts.buffer == 100.0
      assert opts.precision == 6
      assert opts.centroid == true
      assert opts.geometry == false
      assert opts.fields == ["name", "highway"]
      assert MapSet.member?(opts.include, :bbox)
      assert opts.sort == :distance
    end
  end
end
