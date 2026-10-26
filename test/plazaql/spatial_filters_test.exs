defmodule PlazaQL.SpatialFiltersTest do
  @moduledoc "Several spatial methods on one search all apply (ANDed)."
  use ExUnit.Case, async: true

  defp plan!(source) do
    {:ok, %{plans: [plan | _]}} = PlazaQL.compile(source)
    plan
  end

  test "around then within keeps both" do
    plan =
      plan!(~s|$c = boundary(name: "Paris"); search(node).around(500, point(1, 2)).within($c);|)

    assert plan.spatial_filter == {:around, 1, 2, 500}
    assert plan.spatial_filters == [{:predicate, :within, {:set_ref, "c"}}]
  end

  test "within then intersects keeps both, in order" do
    plan =
      plan!(
        "search(way).within(bbox(1, 2, 3, 4)).intersects(linestring(point(1, 2), point(3, 4)));"
      )

    assert {:predicate, :within, {:polygon, _}} = plan.spatial_filter
    assert [{:predicate, :intersects, {:linestring, _}}] = plan.spatial_filters
  end

  test "two arounds are both required" do
    plan = plan!("search(node).around(500, point(1, 2)).around(300, point(1.001, 2.001));")
    assert plan.spatial_filter == {:around, 1, 2, 500}
    assert plan.spatial_filters == [{:around, 1.001, 2.001, 300}]
  end

  test "a #within directive and a method both apply" do
    plan = plan!(~s|#within(boundary(name: "Berlin")); search(node).around(100, point(1, 2));|)
    assert plan.spatial_filter == {:predicate, :within, {:set_ref, "boundary#1"}}
    assert plan.spatial_filters == [{:around, 1, 2, 100}]
  end

  test ".bbox(south:, west:, north:, east:) and #bbox(...)" do
    assert plan!("search(node).bbox(south: 1, west: 2, north: 3, east: 4);").spatial_filter ==
             {:bbox, 1, 2, 3, 4}

    assert plan!("#bbox(south: 1.0, west: 2.0, north: 3.0, east: 4.0); search(node);").spatial_filter ==
             {:bbox, 1.0, 2.0, 3.0, 4.0}
  end

  test "unreadable bbox and h3 arguments are errors, not dropped filters" do
    assert {:error, [%{message: m}]} = PlazaQL.compile("search(node).bbox(1, 2, 3);")
    assert m =~ "expected bbox(south, west, north, east) numbers"

    assert {:error, [%{message: m}]} = PlazaQL.compile("search(node).h3(5);")
    assert m =~ "expected an H3 cell string"
  end

  test "the SQL ANDs every filter" do
    {:ok, %{plans: [plan]}} =
      PlazaQL.compile("search(node).around(500, point(1, 2)).bbox(0, 0, 3, 3);")

    {:ok, query} = PlazaQL.SQL.to_sql(plan)
    assert query.sql =~ "ST_DWithin"
    assert query.sql =~ "ST_MakeEnvelope"
  end
end
