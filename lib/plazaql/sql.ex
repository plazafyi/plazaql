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

  ## One query, or one per branch

  A plan reads one or more **branches**: its element types, then its custom
  sources (`PlazaQL.Schema.Source`). `to_sql/2` joins them into one statement
  (UNION ALL), which needs every branch to return the same columns.
  `branches/2` returns one self-contained query per branch instead, for
  callers that run them separately (branches with different columns, or
  results merged in the application).

  Row queries are totally ordered: by the sort (if any), then the branch's
  key columns. A sorted query also returns each row's sort value as
  `sort_key`, so rows of several branches merge on
  `(sort_key, branch rank, keys)` — the same order `PlazaQL.Plan.seek`
  resumes from for keyset pagination.
  """

  alias PlazaQL.NotCompilable
  alias PlazaQL.Plan
  alias PlazaQL.Plan.OutputOptions
  alias PlazaQL.Query
  alias PlazaQL.Schema
  alias PlazaQL.SQL.Branch
  alias PlazaQL.SQL.Builder

  @aggregation_modes [:count, :sum, :min, :max, :avg]

  @doc """
  Compile a plan to one query per branch: `[{branch, Query.t()}]`, where a
  branch is an element type or a source name, in rank order.

  Each query has its own `$1..$n` parameters. Branch ranks follow the plan
  (element types, then sources), so keyset conditions (`plan.seek`) are right
  for every branch. Set operations are not combined here: run each operand's
  branches, or use `to_sql/2`.
  """
  @spec branches(Plan.t(), Schema.t()) ::
          {:ok, [{Branch.name(), Query.t()}]} | {:error, NotCompilable.t()}
  def branches(plan, schema \\ Schema.new())

  def branches(%Plan{kind: :computation} = plan, schema), do: to_sql(plan, schema)
  def branches(%Plan{output_mode: :tile} = plan, schema), do: to_sql(plan, schema)

  def branches(%Plan{set_ops: [_ | _]} = plan, _schema) do
    {:error,
     %NotCompilable{
       reason: :set_ops,
       plan: plan,
       message: "branches/2 compiles one search; combine set operations with to_sql/2"
     }}
  end

  def branches(%Plan{} = plan, %Schema{} = schema) do
    queries =
      for branch <- Branch.all(plan, schema) do
        {sql, params, _idx} = Builder.build_select(plan, branch, schema)
        {branch.name, %Query{sql: sql, params: params, plan: plan}}
      end

    {:ok, queries}
  rescue
    e in NotCompilable -> {:error, %{e | plan: plan}}
  end

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

  # `.tile(z, x, y)` output is a Mapbox Vector Tile the server renders
  # (ST_AsMVT per layer), not a row set.
  def to_sql(%Plan{output_mode: :tile} = plan, _schema) do
    {:error,
     %NotCompilable{
       reason: :tile,
       plan: plan,
       message: "`.tile()` output is rendered by the server as a vector tile, not SQL rows"
     }}
  end

  def to_sql(%Plan{kind: :query} = plan, schema) do
    {sql, params} = build_query(plan, schema)
    {:ok, %Query{sql: sql, params: params, plan: plan}}
  rescue
    # Raised by SQL builders for parts of the plan that need executor-side
    # resolution first (e.g. {:set_ref, name} geometries)
    e in NotCompilable -> {:error, %{e | plan: plan}}
  end

  defp build_query(%Plan{set_ops: []} = plan, schema) do
    if plan.output_mode in @aggregation_modes and length(Branch.all(plan, schema)) > 1 do
      build_aggregation_query(plan, schema)
    else
      build_union_all_query(plan, schema)
    end
  end

  defp build_query(plan, schema), do: build_set_ops_query(plan, schema)

  # ── UNION ALL (multi-type, non-aggregation) ──────────────────────

  defp build_union_all_query(plan, schema) do
    case Branch.all(plan, schema) do
      [branch] ->
        {sql, params, _idx} = Builder.build_select(plan, branch, schema)
        {sql, params}

      branches ->
        # Each branch fetches limit + offset (twice over, so the merge has
        # room); the merged rows are ordered and cut once.
        branch_plan =
          if plan.limit,
            do: %{plan | limit: ((plan.offset || 0) + plan.limit) * 2, offset: nil},
            else: %{plan | offset: nil}

        {parts, all_params, next_idx} =
          Enum.reduce(branches, {[], [], 1}, fn branch, {sqls, params, idx} ->
            {sql, new_params, new_idx} = Builder.build_select(branch_plan, branch, schema, idx)
            {["(#{sql})" | sqls], params ++ new_params, new_idx}
          end)

        union_sql = Enum.join(Enum.reverse(parts), "\nUNION ALL\n")

        {tail, tail_params, _idx} =
          Enum.reduce([{"LIMIT", plan.limit}, {"OFFSET", plan.offset}], {"", [], next_idx}, fn
            {_kw, nil}, acc -> acc
            {kw, value}, {sql, ps, i} -> {sql <> "\n#{kw} $#{i}", ps ++ [value], i + 1}
          end)

        case merged_order(plan, hd(branches)) do
          nil ->
            {"#{union_sql}#{tail}", all_params ++ tail_params}

          order_sql ->
            {"SELECT * FROM (\n#{union_sql}\n) AS branches\n#{order_sql}#{tail}",
             all_params ++ tail_params}
        end
    end
  end

  # Rows of several branches merge on (sort value, branch rank, keys): the
  # rank is the branch's position, recovered from its `__type__` label.
  defp merged_order(%Plan{output_mode: mode} = plan, branch)
       when mode in [:full, :ids, :keys, :skel, :tags] do
    keys = Enum.map_join(branch.keys, ", ", &"#{&1} ASC")
    labels = plan.element_types ++ (plan.sources || [])

    rank =
      labels
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {name, i} ->
        label = Branch.resolve(name, branch.schema, i).label
        "WHEN '#{label}' THEN #{i}"
      end)

    sort =
      case sort_direction(plan) do
        nil -> ""
        dir -> "sort_key #{dir}, "
      end

    "ORDER BY #{sort}CASE __type__ #{rank} END, #{keys}"
  end

  defp merged_order(_plan, _branch), do: nil

  defp sort_direction(%Plan{sort_expr: {expr, :desc}}) when expr != nil, do: "DESC"
  defp sort_direction(%Plan{sort_expr: {expr, _asc}}) when expr != nil, do: "ASC"
  defp sort_direction(%Plan{output_options: %OutputOptions{sort: :name}}), do: "ASC NULLS LAST"
  defp sort_direction(%Plan{output_options: %OutputOptions{sort: sort}}) when sort != nil, do: "ASC"
  defp sort_direction(_plan), do: nil

  # ── Cross-type aggregation wrapper ──────────────────────────────

  defp build_aggregation_query(plan, schema) do
    {inner_branches, all_params, _next_idx} =
      Enum.reduce(Branch.all(plan, schema), {[], [], 1}, fn branch, {sqls, params, idx} ->
        {sql, new_params, new_idx} = Builder.build_select(plan, branch, schema, idx)
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

  # Operands are combined as sets, so they are not sorted.
  defp build_set_ops_query(plan, schema) do
    plan = unsorted(plan)
    base_plan = %{plan | set_ops: []}
    {base_sql, base_params, next_idx} = build_multi_type_raw(base_plan, schema, 1)

    {ctes, final_select, all_params, _next_idx} =
      Enum.reduce(
        Enum.with_index(plan.set_ops),
        {[{"base", base_sql}], nil, base_params, next_idx},
        fn
          {{:difference, [_left, right]}, i}, {ctes, _sel, params, idx} ->
            right = unsorted(inherit_spatial(right, plan))
            {sub_sql, sub_params, next_idx} = build_multi_type_raw(right, schema, idx)
            cte_name = "difference_#{i}"
            final = set_op_select(:difference, cte_name, schema)
            {ctes ++ [{cte_name, sub_sql}], final, params ++ sub_params, next_idx}

          {{op, sub_plan}, i}, {ctes, _sel, params, idx} ->
            sub_plan = unsorted(inherit_spatial(sub_plan, plan))
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

  defp unsorted(%Plan{output_options: %OutputOptions{} = opts} = plan),
    do: %{plan | sort_expr: nil, output_options: %{opts | sort: nil}}

  defp unsorted(%Plan{} = plan), do: %{plan | sort_expr: nil}

  defp inherit_spatial(%Plan{spatial_filter: nil} = sub, %Plan{} = parent) do
    %{sub | spatial_filter: parent.spatial_filter, spatial_filters: parent.spatial_filters}
  end

  defp inherit_spatial(sub, _parent), do: sub

  # ── Raw multi-type SQL (no wrapping) ────────────────────────────

  defp build_multi_type_raw(plan, schema, start_idx) do
    case Branch.all(plan, schema) do
      [branch] ->
        Builder.build_select(plan, branch, schema, start_idx)

      branches ->
        {branches, all_params, next_idx} =
          Enum.reduce(branches, {[], [], start_idx}, fn branch, {sqls, params, idx} ->
            {sql, new_params, new_idx} = Builder.build_select(plan, branch, schema, idx)
            {["(#{sql})" | sqls], params ++ new_params, new_idx}
          end)

        union_sql = Enum.join(Enum.reverse(branches), "\nUNION ALL\n")
        {union_sql, all_params, next_idx}
    end
  end
end
