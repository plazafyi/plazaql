defmodule PlazaQL.QueryTest do
  use ExUnit.Case, async: true

  alias PlazaQL.NotCompilable
  alias PlazaQL.Query

  describe "Query struct" do
    test "creates with sql and params" do
      query = %Query{sql: "SELECT * FROM osm_nodes WHERE $1", params: [42]}
      assert query.sql == "SELECT * FROM osm_nodes WHERE $1"
      assert query.params == [42]
    end

    test "defaults metadata to empty map and plan to nil" do
      query = %Query{sql: "SELECT 1", params: []}
      assert query.metadata == %{}
      assert query.plan == nil
    end
  end

  describe "NotCompilable" do
    test "can be raised and caught" do
      assert_raise NotCompilable, fn ->
        raise NotCompilable, reason: :route, plan: nil, message: ""
      end
    end

    test "formats message from reason when message is empty" do
      error = %NotCompilable{reason: :isochrone, plan: nil, message: ""}
      assert NotCompilable.message(error) == "plan is not compilable to SQL: isochrone"
    end

    test "uses custom message when provided" do
      error = %NotCompilable{reason: :route, plan: nil, message: "routing requires a service"}
      assert NotCompilable.message(error) == "routing requires a service"
    end
  end
end
