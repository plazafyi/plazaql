defmodule PlazaQL.SQL do
  @moduledoc """
  Compiles a `PlazaQL.Plan` to a parameterized SQL query.

  Returns a `PlazaQL.Query` containing a single SQL string and params list,
  ready to execute against any PostGIS database with the configured schema.

  ## Examples

      schema = PlazaQL.Schema.new()
      plan = %PlazaQL.Plan{element_types: [:node], tag_filters: [{:eq, "amenity", "cafe"}]}
      {:ok, %PlazaQL.Query{sql: sql, params: params}} = PlazaQL.SQL.to_sql(plan, schema)

  Multi-type queries produce a UNION ALL:

      plan = %PlazaQL.Plan{element_types: [:node, :way]}
      {:ok, query} = PlazaQL.SQL.to_sql(plan, schema)
      # query.sql contains UNION ALL across both types

  Computation plans return an error:

      plan = %PlazaQL.Plan{kind: :computation, computation: {:route, %{}}}
      {:error, %PlazaQL.NotCompilable{}} = PlazaQL.SQL.to_sql(plan, schema)
  """

  alias PlazaQL.NotCompilable
  alias PlazaQL.Plan
  alias PlazaQL.Query
  alias PlazaQL.Schema
  alias PlazaQL.SQL.Builder

  @aggregation_modes [:count, :sum, :min, :max, :avg]

  @doc """
  Compile a Plan to a parameterized SQL query.

  Returns `{:ok, PlazaQL.Query.t()}` or `{:error, PlazaQL.NotCompilable.t()}`.
  """
  @spec to_sql(Plan.t(), Schema.t()) :: {:ok, Query.t()} | {:error, NotCompilable.t()}
  def to_sql(plan, schema \\ Schema.new())

  def to_sql(%Plan{kind: :computation} = plan, _schema) do
    {comp_type, _} = plan.computation
    {:error, %NotCompilable{reason: comp_type, plan: plan}}
  end

  def to_sql(%Plan{kind: :query, set_ops: []} = plan, schema) do
    {sql, params} =
      if plan.output_mode in @aggregation_modes and length(plan.element_types) > 1 do
        build_aggregation_query(plan, schema)
      else
        build_union_all_query(plan, schema)
      end

    {:ok, %Query{sql: sql, params: params, plan: plan}}
  end

  def to_sql(%Plan{kind: :query} = plan, schema) do
    {sql, params} = build_set_ops_query(plan, schema)
    {:ok, %Query{sql: sql, params: params, plan: plan}}
  end

  # ── UNION ALL (multi-type, non-aggregation) ──────────────────────

  defp build_union_all_query(plan, schema) do
    types = plan.element_types

    if length(types) == 1 do
      {sql, params, _idx} = Builder.build_select(plan, hd(types), schema)
      {sql, params}
    else
      branch_plan = if plan.limit, do: %{plan | limit: plan.limit * 2}, else: plan

      {branches, all_params, next_idx} =
        Enum.reduce(types, {[], [], 1}, fn type, {sqls, params, idx} ->
          {sql, new_params, new_idx} = Builder.build_select(branch_plan, type, schema, idx)
          {["(#{sql})" | sqls], params ++ new_params, new_idx}
        end)

      union_sql = Enum.join(Enum.reverse(branches), "\nUNION ALL\n")

      if plan.limit do
        {"#{union_sql}\nLIMIT $#{next_idx}", all_params ++ [plan.limit]}
      else
        {union_sql, all_params}
      end
    end
  end

  # ── Cross-type aggregation wrapper ──────────────────────────────

  defp build_aggregation_query(plan, schema) do
    types = plan.element_types

    {inner_branches, all_params, _next_idx} =
      Enum.reduce(types, {[], [], 1}, fn type, {sqls, params, idx} ->
        {sql, new_params, new_idx} = Builder.build_select(plan, type, schema, idx)
        {["(#{sql})" | sqls], params ++ new_params, new_idx}
      end)

    inner_sql = Enum.join(Enum.reverse(inner_branches), "\nUNION ALL\n")

    outer_sql = aggregation_outer(plan.output_mode, plan.group_by, inner_sql)
    {outer_sql, all_params}
  end

  defp aggregation_outer(:count, nil, inner),
    do: "SELECT SUM(cnt) AS total FROM (\n#{inner}\n) sub"

  defp aggregation_outer(:count, _group, inner),
    do: "SELECT group_key, SUM(cnt) AS total FROM (\n#{inner}\n) sub GROUP BY group_key"

  defp aggregation_outer(:avg, nil, inner),
    do: "SELECT SUM(avg_val * cnt) / NULLIF(SUM(cnt), 0) AS value FROM (\n#{inner}\n) sub"

  defp aggregation_outer(:avg, _group, inner),
    do:
      "SELECT group_key, SUM(avg_val * cnt) / NULLIF(SUM(cnt), 0) AS value FROM (\n#{inner}\n) sub GROUP BY group_key"

  defp aggregation_outer(mode, nil, inner) when mode in [:sum, :min, :max] do
    func = String.upcase(Atom.to_string(mode))
    "SELECT #{func}(value) AS value FROM (\n#{inner}\n) sub"
  end

  defp aggregation_outer(mode, _group, inner) when mode in [:sum, :min, :max] do
    func = String.upcase(Atom.to_string(mode))
    "SELECT group_key, #{func}(value) AS value FROM (\n#{inner}\n) sub GROUP BY group_key"
  end

  # ── Set operations via CTEs ─────────────────────────────────────

  defp build_set_ops_query(plan, schema) do
    base_plan = %{plan | set_ops: []}
    {base_sql, base_params, next_idx} = build_multi_type_raw(base_plan, schema, 1)

    {ctes, final_select, all_params, _next_idx} =
      Enum.reduce(
        Enum.with_index(plan.set_ops),
        {[{"base", base_sql}], nil, base_params, next_idx},
        fn
          {{:difference, [_left, right]}, i}, {ctes, _sel, params, idx} ->
            right = inherit_spatial(right, plan)
            {sub_sql, sub_params, next_idx} = build_multi_type_raw(right, schema, idx)
            cte_name = "difference_#{i}"
            final = set_op_select(:difference, cte_name, schema)
            {ctes ++ [{cte_name, sub_sql}], final, params ++ sub_params, next_idx}

          {{op, sub_plan}, i}, {ctes, _sel, params, idx} ->
            sub_plan = inherit_spatial(sub_plan, plan)
            {sub_sql, sub_params, next_idx} = build_multi_type_raw(sub_plan, schema, idx)
            cte_name = "#{op}_#{i}"
            final = set_op_select(op, cte_name, schema)
            {ctes ++ [{cte_name, sub_sql}], final, params ++ sub_params, next_idx}
        end
      )

    cte_parts =
      Enum.map_join(ctes, ",\n", fn {name, sql} ->
        "#{name} AS (\n#{sql}\n)"
      end)

    full_sql = "WITH #{cte_parts}\n#{final_select}"
    {full_sql, all_params}
  end

  defp set_op_select(:union, cte_name, _schema) do
    "SELECT * FROM base\nUNION\nSELECT * FROM #{cte_name}"
  end

  defp set_op_select(:difference, cte_name, schema) do
    id = schema.columns.id

    "SELECT b.* FROM base b\n" <>
      "WHERE NOT EXISTS (SELECT 1 FROM #{cte_name} x WHERE x.#{id} = b.#{id} AND x.__type__ = b.__type__)"
  end

  defp set_op_select(:intersection, cte_name, schema) do
    id = schema.columns.id

    "SELECT b.* FROM base b\n" <>
      "WHERE EXISTS (SELECT 1 FROM #{cte_name} i WHERE i.#{id} = b.#{id} AND i.__type__ = b.__type__)"
  end

  defp inherit_spatial(%Plan{spatial_filter: nil} = sub, %Plan{spatial_filter: parent_spatial}) do
    %{sub | spatial_filter: parent_spatial}
  end

  defp inherit_spatial(sub, _parent), do: sub

  # ── Raw multi-type SQL (no wrapping) ────────────────────────────

  defp build_multi_type_raw(plan, schema, start_idx) do
    types = plan.element_types

    if length(types) == 1 do
      Builder.build_select(plan, hd(types), schema, start_idx)
    else
      {branches, all_params, next_idx} =
        Enum.reduce(types, {[], [], start_idx}, fn type, {sqls, params, idx} ->
          {sql, new_params, new_idx} = Builder.build_select(plan, type, schema, idx)
          {["(#{sql})" | sqls], params ++ new_params, new_idx}
        end)

      union_sql = Enum.join(Enum.reverse(branches), "\nUNION ALL\n")
      {union_sql, all_params, next_idx}
    end
  end
end
