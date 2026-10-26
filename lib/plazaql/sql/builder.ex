defmodule PlazaQL.SQL.Builder do
  @moduledoc false
  # Internal: assembles a complete SELECT query for one branch (an element
  # type's table or a custom source).

  alias PlazaQL.Plan
  alias PlazaQL.Plan.OutputOptions
  alias PlazaQL.Schema
  alias PlazaQL.SQL.Branch
  alias PlazaQL.SQL.Expression
  alias PlazaQL.SQL.Sort
  alias PlazaQL.SQL.Where

  @row_modes [:full, :ids, :keys, :skel, :tags]
  @aggregate_modes [:sum, :min, :max, :avg]

  @doc """
  Build a complete SELECT query for one branch: an element type (ranked at
  its index in `plan.element_types`), a source name, or a resolved branch.
  """
  @spec build_select(Plan.t(), Branch.name() | Branch.t(), Schema.t(), pos_integer()) ::
          {String.t(), [term()], pos_integer()}
  def build_select(%Plan{} = plan, branch, %Schema{} = schema, idx \\ 1) do
    branch = resolve_branch(branch, plan, schema)
    plan = Branch.bind_type(plan, branch)
    sort = if plan.output_mode in @row_modes, do: Sort.spec(plan, branch)

    {select_sql, select_params, idx2} = build_select_columns(plan, branch, sort, idx)
    {where_sql, where_params, idx3} = Where.build_where(plan, branch, idx2)
    {group_sql, group_params, idx4} = build_group_by(plan, idx3)
    {order_sql, order_params, idx5} = build_order_by(plan, branch, sort, idx4)
    {limit_sql, limit_params, idx6} = build_limit(plan, idx5)
    {offset_sql, offset_params, idx7} = build_offset(plan, idx6)

    distinct = if plan.distinct, do: "DISTINCT ", else: ""

    parts =
      ["SELECT #{distinct}#{select_sql}", "FROM #{branch.table}"]
      |> maybe_append(where_sql)
      |> maybe_append(group_sql)
      |> maybe_append(order_sql)
      |> maybe_append(limit_sql)
      |> maybe_append(offset_sql)

    sql = Enum.join(parts, " ")

    params =
      select_params ++ where_params ++ group_params ++ order_params ++ limit_params ++ offset_params

    {sql, params, idx7}
  end

  defp resolve_branch(%Branch{} = branch, _plan, _schema), do: branch
  defp resolve_branch(name, plan, schema), do: Branch.resolve(name, schema, Branch.rank(plan, name))

  # ── SELECT columns ────────────────────────────────────────────────

  defp build_select_columns(plan, branch, sort, idx) do
    schema = branch.schema
    type_lit = "'#{branch.label}' AS __type__"

    case plan.output_mode do
      mode when mode in @row_modes ->
        {geom_sql, geom_params, idx2} = row_geometry(mode, schema, plan.output_options, idx)

        {computed_sql, computed_params, idx3} =
          build_computed_columns(computed_columns(plan), schema, idx2)

        {sort_sql, sort_params, idx4} = Sort.key_column(sort, idx3)

        cols =
          row_columns(mode, branch)
          |> maybe_append_geom(geom_sql)
          |> Enum.concat(if mode == :full, do: branch.full_columns, else: [])
          |> Enum.concat(computed_sql)
          |> Enum.concat(sort_sql)
          |> Enum.concat([type_lit])

        {Enum.join(cols, ", "), geom_params ++ computed_params ++ sort_params, idx4}

      :count ->
        build_count_select(plan, schema, type_lit, idx)

      agg when agg in @aggregate_modes ->
        build_aggregate_select(plan, agg, schema, type_lit, idx)
    end
  end

  # The columns a row of each mode carries, before geometry and extras.
  defp row_columns(:full, branch), do: branch.keys ++ [branch.schema.columns.tags]
  defp row_columns(:tags, branch), do: branch.keys ++ [branch.schema.columns.tags]
  defp row_columns(mode, branch) when mode in [:ids, :skel], do: branch.keys

  # An element's identity, plus its partition key where the table has one.
  defp row_columns(:keys, %Branch{partitioned?: true} = branch),
    do: branch.keys ++ [branch.schema.columns.partition_tile_id]

  defp row_columns(:keys, branch), do: branch.keys

  defp maybe_append_geom(cols, nil), do: cols
  defp maybe_append_geom(cols, geom_sql), do: cols ++ [geom_sql]

  # ── Geometry transforms ──────────────────────────────────────────

  defp row_geometry(mode, schema, opts, idx) when mode in [:full, :skel],
    do: geometry_select(schema, opts, idx)

  defp row_geometry(_mode, _schema, _opts, idx), do: {nil, [], idx}

  defp geometry_select(schema, nil, idx) do
    {schema.columns.geometry, [], idx}
  end

  defp geometry_select(_schema, %OutputOptions{geometry: false}, idx) do
    {nil, [], idx}
  end

  defp geometry_select(schema, %OutputOptions{} = opts, idx) do
    geom = schema.columns.geometry

    case apply_geom_transforms(geom, opts, idx) do
      {^geom, [], idx} -> {geom, [], idx}
      # The transformed geometry keeps the column's name.
      {sql, params, idx} -> {"#{sql} AS #{geom}", params, idx}
    end
  end

  # Order: simplify, then buffer, then centroid.
  defp apply_geom_transforms(geom, %OutputOptions{} = opts, idx) do
    {geom, params, idx} = maybe_simplify(geom, opts.simplify, idx)
    {geom, params2, idx} = maybe_buffer(geom, opts.buffer, idx)
    geom = maybe_centroid(geom, opts.centroid)
    {geom, params ++ params2, idx}
  end

  defp maybe_simplify(geom, nil, idx), do: {geom, [], idx}

  defp maybe_simplify(geom, meters, idx) do
    degrees = meters_to_degrees(meters)
    {"ST_SimplifyPreserveTopology(#{geom}, $#{idx})", [degrees], idx + 1}
  end

  defp maybe_buffer(geom, nil, idx), do: {geom, [], idx}

  defp maybe_buffer(geom, buffer, idx) do
    {"ST_Buffer(#{geom}::geography, $#{idx})::geometry", [buffer / 1.0], idx + 1}
  end

  defp maybe_centroid(geom, true), do: "ST_Centroid(#{geom})"
  defp maybe_centroid(geom, _no), do: geom

  # Approximate meters to degrees for the simplification tolerance
  defp meters_to_degrees(meters), do: meters / 111_320.0

  # ── Computed columns ─────────────────────────────────────────────

  # `.include("distance")` measures from the around point, unless the plan
  # already computes a distance.
  defp computed_columns(
         %Plan{computed_columns: cols, output_options: %OutputOptions{} = opts} = plan
       ) do
    with true <- MapSet.member?(opts.include, :distance),
         false <- Keyword.has_key?(cols, :distance_m),
         {lat, lng} <- Sort.reference_point(plan) do
      cols ++ [distance_m: {:geom_func, :distance, {lat, lng}, nil}]
    else
      _ -> cols
    end
  end

  defp computed_columns(%Plan{computed_columns: cols}), do: cols

  defp build_computed_columns([], _schema, idx), do: {[], [], idx}

  @identifier_re ~r/^[a-z_][a-z0-9_]*$/

  defp build_computed_columns(columns, schema, idx) do
    {sqls, params, next_idx} =
      Enum.reduce(columns, {[], [], idx}, fn {col_name, expr}, {sqls, ps, i} ->
        alias_str = Atom.to_string(col_name)

        unless Regex.match?(@identifier_re, alias_str) do
          raise ArgumentError,
                "invalid computed column alias #{inspect(col_name)}: must match ~r/^[a-z_][a-z0-9_]*$/"
        end

        {expr_sql, expr_params, next_i} = Expression.to_sql(expr, schema, i)
        sql = "#{expr_sql} AS #{alias_str}"
        {[sql | sqls], ps ++ expr_params, next_i}
      end)

    {Enum.reverse(sqls), params, next_idx}
  end

  # ── Count select ─────────────────────────────────────────────────

  defp build_count_select(plan, schema, type_lit, idx) do
    case plan.group_by do
      nil ->
        {"COUNT(*) AS cnt, #{type_lit}", [], idx}

      group_expr ->
        {group_sql, group_params, idx2} = Expression.to_sql(group_expr, schema, idx)
        {"#{group_sql} AS group_key, COUNT(*) AS cnt, #{type_lit}", group_params, idx2}
    end
  end

  # ── Aggregate select ─────────────────────────────────────────────

  # SUM/MIN/MAX keep the expression's type (numeric for number(...), double
  # precision for geometry measures); AVG is a float, with the row count so
  # averages of several branches can be weighted.
  defp build_aggregate_select(plan, agg, schema, type_lit, idx) do
    {group_sql, group_params, idx2} =
      case plan.group_by do
        nil -> {nil, [], idx}
        group_expr -> Expression.to_sql(group_expr, schema, idx)
      end

    {expr_sql, expr_params, idx3} = Expression.to_sql(plan.aggregate_expr, schema, idx2)

    value_sql =
      case agg do
        :avg -> "AVG(#{expr_sql})::float AS avg_val, COUNT(*) AS cnt"
        _ -> "#{aggregate_function(agg)}(#{expr_sql}) AS value"
      end

    group_col = if group_sql, do: "#{group_sql} AS group_key, ", else: ""
    {"#{group_col}#{value_sql}, #{type_lit}", group_params ++ expr_params, idx3}
  end

  defp aggregate_function(:sum), do: "SUM"
  defp aggregate_function(:min), do: "MIN"
  defp aggregate_function(:max), do: "MAX"

  # ── GROUP BY ─────────────────────────────────────────────────────

  # The group key is the first select column.
  defp build_group_by(%Plan{group_by: nil}, idx), do: {"", [], idx}

  defp build_group_by(%Plan{output_mode: mode}, idx) when mode in [:count | @aggregate_modes],
    do: {"GROUP BY 1", [], idx}

  defp build_group_by(_plan, idx), do: {"", [], idx}

  # ── ORDER BY ─────────────────────────────────────────────────────

  # Rows have one total order: the sort, then the branch's keys.
  defp build_order_by(%Plan{output_mode: mode}, branch, sort, idx) when mode in @row_modes,
    do: Sort.order_by(sort, branch, idx)

  defp build_order_by(_plan, _branch, _sort, idx), do: {"", [], idx}

  # ── LIMIT / OFFSET ──────────────────────────────────────────────

  defp build_limit(%Plan{limit: nil}, idx), do: {"", [], idx}

  defp build_limit(%Plan{limit: limit}, idx) do
    {"LIMIT $#{idx}", [limit], idx + 1}
  end

  defp build_offset(%Plan{offset: nil}, idx), do: {"", [], idx}

  defp build_offset(%Plan{offset: offset}, idx) do
    {"OFFSET $#{idx}", [offset], idx + 1}
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp maybe_append(parts, ""), do: parts
  defp maybe_append(parts, part), do: parts ++ [part]
end
