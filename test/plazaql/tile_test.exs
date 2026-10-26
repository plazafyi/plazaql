defmodule PlazaQL.TileTest do
  use ExUnit.Case, async: true

  alias PlazaQL.Plan

  defp compile_plan(source) do
    {:ok, %{plans: [plan | _]}} = PlazaQL.compile(source)
    plan
  end

  defp errors(source) do
    {:error, errors} = PlazaQL.compile(source)
    Enum.map(errors, & &1.message)
  end

  describe ".tile(z, x, y)" do
    test "compiles to a tile output with the search's filters" do
      plan =
        compile_plan(
          ~s|search(node, amenity: "restaurant", cuisine: *).fields("name").tile(14, 4823, 6160);|
        )

      assert plan.output_mode == :tile
      assert plan.tile == %{z: 14, x: 4823, y: 6160, layers: nil}
      assert plan.element_types == [:node]
      assert {:eq, "amenity", "restaurant"} in plan.tag_filters
      assert {:exists, "cuisine"} in plan.tag_filters
      assert plan.output_options.fields == ["name"]
    end

    test "takes a list of layers" do
      plan =
        compile_plan(~s|search(nwr, shop: *).tile(12, 1205, 1540, layers: ["pois", "buildings"]);|)

      assert plan.tile.layers == ["pois", "buildings"]
    end

    test "takes layers as a comma-separated string" do
      plan = compile_plan(~s|search(way, building: *).tile(15, 9647, 12320, layers: "buildings");|)
      assert plan.tile.layers == ["buildings"]
    end

    test "is not SQL-compilable" do
      plan = compile_plan(~s|search(node, amenity: "cafe").tile(14, 4823, 6160);|)
      assert {:error, %PlazaQL.NotCompilable{reason: :tile}} = PlazaQL.SQL.to_sql(plan)
    end

    test "rejects missing or non-integer coordinates" do
      assert [msg | _] = errors(~s|search(node, amenity: "cafe").tile(14, 2);|)
      assert msg =~ "three integer arguments"

      assert [msg | _] = errors(~s|search(node, amenity: "cafe").tile(14, 2.5, 3);|)
      assert msg =~ "three integer arguments"
    end

    test "rejects coordinates outside the zoom's grid" do
      assert [msg | _] = errors(~s|search(node, amenity: "cafe").tile(2, 4, 0);|)
      assert msg =~ "outside the grid"
    end

    test "rejects unknown keyword arguments and bad layers" do
      assert [msg | _] = errors(~s|search(node, amenity: "cafe").tile(2, 1, 1, format: "pbf");|)
      assert msg =~ "unknown `.tile()` argument"

      assert [msg | _] = errors(~s|search(node, amenity: "cafe").tile(2, 1, 1, layers: 5);|)
      assert msg =~ "layers:"
    end

    test "is a terminal output mode" do
      assert [msg | _] = errors(~s|search(node, amenity: "cafe").tile(2, 1, 1).limit(5);|)
      assert msg =~ "output modes must be last"

      assert [msg | _] = errors(~s|search(node, amenity: "cafe").count().tile(2, 1, 1);|)
      assert msg =~ "output mode"
    end

    test "only applies to search results" do
      assert [msg | _] = errors(~s|boundary(name: "Paris").tile(2, 1, 1);|)
      assert msg =~ "`.tile()` cannot be applied to"
    end

    test "round-trips through the formatter" do
      source = ~s|search(node, amenity: "cafe").tile(14, 4823, 6160, layers: ["pois"]);|
      {:ok, formatted} = PlazaQL.format(source)
      assert formatted =~ ".tile(14, 4823, 6160, layers: [\"pois\"])"
      assert %Plan{output_mode: :tile} = compile_plan(formatted)
    end
  end
end
