defmodule PlazaQL.SQL.Builder do
  @moduledoc false
  # Internal: assembles a complete SELECT query for a single element type.

  alias PlazaQL.Plan
  alias PlazaQL.Plan.OutputOptions
  alias PlazaQL.Schema
  alias PlazaQL.SQL.Expression
  alias PlazaQL.SQL.Where

  @type acc :: {String.t(), [term()], pos_integer()}

  @doc "Build a complete SELECT query for one element type."
  @spec build_select(Plan.t(), Plan.element_type(), Schema.t(), pos_integer()) ::
          {String.t(), [term()], pos_integer()}
  def build_select(%Plan{} = plan, element_type, %Schema{} = schema, idx \\ 1) do
    table = table_for_type(element_type, schema)

    {select_sql, select_params, idx2} =
      build_select_columns(plan, element_type, schema, idx)

    {where_sql, where_params, idx3} = Where.build_where(plan, schema, idx2)

    {group_sql, group_params, idx4} = build_group_by(plan, schema, idx3)
    {order_sql, order_params, idx5} = build_order_by(plan, schema, idx4)
    {limit_sql, limit_params, idx6} = build_limit(plan, idx5)
    {offset_sql, offset_params, idx7} = build_offset(plan, idx6)

    distinct = if plan.distinct, do: "DISTINCT ", else: ""

    parts =
      ["SELECT #{distinct}#{select_sql}", "FROM #{table}"]
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

  # ── Table lookup ──────────────────────────────────────────────────

  defp table_for_type(:node, schema), do: schema.tables.node
  defp table_for_type(:way, schema), do: schema.tables.way
  defp table_for_type(:relation, schema), do: schema.tables.relation
  defp table_for_type(:boundary, schema), do: schema.tables.relation

  defp type_label(:node), do: "node"
  defp type_label(:way), do: "way"
  defp type_label(:relation), do: "relation"
  defp type_label(:boundary), do: "boundary"

  # ── SELECT columns ────────────────────────────────────────────────

  defp build_select_columns(plan, element_type, schema, idx) do
    type_lit = "'#{type_label(element_type)}' AS __type__"

    case plan.output_mode do
      :full ->
        {geom_sql, geom_params, idx2} =
          geometry_select(schema, plan.output_options, idx)

        {computed_sql, computed_params, idx3} =
          build_computed_columns(plan.computed_columns, schema, idx2)

        cols =
          [schema.columns.id, schema.columns.tags]
          |> maybe_append_geom(geom_sql)
          |> Enum.concat(computed_sql)
          |> Enum.concat([type_lit])

        {Enum.join(cols, ", "), geom_params ++ computed_params, idx3}

      :ids ->
        {computed_sql, computed_params, idx2} =
          build_computed_columns(plan.computed_columns, schema, idx)

        cols = [schema.columns.id] ++ computed_sql ++ [type_lit]
        {Enum.join(cols, ", "), computed_params, idx2}

      :skel ->
        {geom_sql, geom_params, idx2} =
          geometry_select(schema, plan.output_options, idx)

        {computed_sql, computed_params, idx3} =
          build_computed_columns(plan.computed_columns, schema, idx2)

        cols =
          [schema.columns.id]
          |> maybe_append_geom(geom_sql)
          |> Enum.concat(computed_sql)
          |> Enum.concat([type_lit])

        {Enum.join(cols, ", "), geom_params ++ computed_params, idx3}

      :tags ->
        {computed_sql, computed_params, idx2} =
          build_computed_columns(plan.computed_columns, schema, idx)

        cols = [schema.columns.id, schema.columns.tags] ++ computed_sql ++ [type_lit]
        {Enum.join(cols, ", "), computed_params, idx2}

      :count ->
        build_count_select(plan, schema, type_lit, idx)

      agg when agg in [:sum, :min, :max, :avg] ->
        build_aggregate_select(plan, agg, schema, type_lit, idx)
    end
  end

  defp maybe_append_geom(cols, nil), do: cols
  defp maybe_append_geom(cols, geom_sql), do: cols ++ [geom_sql]

  # ── Geometry transforms ──────────────────────────────────────────

  defp geometry_select(schema, nil, idx) do
    {schema.columns.geometry, [], idx}
  end

  defp geometry_select(_schema, %OutputOptions{geometry: false}, idx) do
    {nil, [], idx}
  end

  defp geometry_select(schema, %OutputOptions{} = opts, idx) do
    geom = schema.columns.geometry
    apply_geom_transforms(geom, opts, idx)
  end

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

  defp maybe_centroid(geom, false), do: geom
  defp maybe_centroid(geom, true), do: "ST_Centroid(#{geom})"

  defp meters_to_degrees(meters), do: meters / 111_320.0

  # ── Computed columns ─────────────────────────────────────────────

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

  defp build_aggregate_select(plan, agg, schema, type_lit, idx) do
    agg_name = String.upcase(Atom.to_string(agg))
    {expr_sql, expr_params, idx2} = Expression.to_sql(plan.aggregate_expr, schema, idx)

    case {agg, plan.group_by} do
      {:avg, nil} ->
        {"#{agg_name}(#{expr_sql})::float AS avg_val, COUNT(*) AS cnt, #{type_lit}", expr_params,
         idx2}

      {:avg, group_expr} ->
        {group_sql, group_params, idx3} = Expression.to_sql(group_expr, schema, idx2)

        {"#{group_sql} AS group_key, #{agg_name}(#{expr_sql})::float AS avg_val, COUNT(*) AS cnt, #{type_lit}",
         expr_params ++ group_params, idx3}

      {_, nil} ->
        {"#{agg_name}(#{expr_sql})::float AS value, #{type_lit}", expr_params, idx2}

      {_, group_expr} ->
        {group_sql, group_params, idx3} = Expression.to_sql(group_expr, schema, idx2)

        {"#{group_sql} AS group_key, #{agg_name}(#{expr_sql})::float AS value, #{type_lit}",
         expr_params ++ group_params, idx3}
    end
  end

  # ── GROUP BY ─────────────────────────────────────────────────────

  defp build_group_by(%Plan{group_by: nil}, _schema, idx), do: {"", [], idx}

  defp build_group_by(%Plan{output_mode: mode}, _schema, idx)
       when mode not in [:count, :sum, :min, :max, :avg],
       do: {"", [], idx}

  defp build_group_by(%Plan{group_by: group_expr}, schema, idx) do
    {group_sql, group_params, next_idx} = Expression.to_sql(group_expr, schema, idx)
    {"GROUP BY #{group_sql}", group_params, next_idx}
  end

  # ── ORDER BY ─────────────────────────────────────────────────────

  defp build_order_by(%Plan{sort_expr: {expr, dir}, output_options: _}, schema, idx) do
    {expr_sql, expr_params, next_idx} = Expression.to_sql(expr, schema, idx)
    direction = if dir == :desc, do: "DESC", else: "ASC"
    {"ORDER BY #{expr_sql} #{direction}", expr_params, next_idx}
  end

  defp build_order_by(%Plan{output_options: %OutputOptions{sort: sort}}, schema, idx)
       when sort != nil do
    {sort_col, params, next_idx} = sort_column(sort, schema, idx)
    {"ORDER BY #{sort_col} ASC", params, next_idx}
  end

  defp build_order_by(_plan, _schema, idx), do: {"", [], idx}

  defp sort_column(:distance, _schema, idx), do: {"distance_m", [], idx}
  defp sort_column(:name, schema, idx), do: {"#{schema.columns.tags}->>'name'", [], idx}
  defp sort_column(:osm_id, schema, idx), do: {schema.columns.id, [], idx}

  defp sort_column(:qt, schema, idx) do
    tile_col =
      schema.columns.tile_id ||
        raise ArgumentError, "tile_id column required for qt sort"

    {tile_col, [], idx}
  end

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
