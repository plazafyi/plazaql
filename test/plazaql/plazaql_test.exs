defmodule PlazaQLTest do
  use ExUnit.Case, async: true

  describe "compile/1" do
    test "end-to-end from source string" do
      {:ok, result} = PlazaQL.compile(~s|$$ = search(node, amenity: "cafe").limit(5);|)
      plan = hd(result.plans)
      assert plan.element_types == [:node]
      assert plan.tag_filters == [{:eq, "amenity", "cafe"}]
      assert plan.limit == 5
    end

    test "returns error on invalid syntax" do
      assert {:error, [%PlazaQL.Error{}]} = PlazaQL.compile("invalid!!!")
    end

    test "compiles computation" do
      {:ok, result} = PlazaQL.compile(~s|$$ = route(point(38.9, -77.0), point(39.0, -76.5));|)
      plan = hd(result.plans)
      assert plan.kind == :computation
    end
  end
end
