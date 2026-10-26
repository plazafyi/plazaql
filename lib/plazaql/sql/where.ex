defmodule PlazaQL.SQL.Where do
  @moduledoc false
  # Internal: builds WHERE clause conditions from Plan filters, for one
  # branch (an element type's table or a custom source).

  alias PlazaQL.NotCompilable
  alias PlazaQL.Plan
  alias PlazaQL.Schema
  alias PlazaQL.SQL.Branch
  alias PlazaQL.SQL.Expression
  alias PlazaQL.SQL.Sort

  @type acc :: {String.t(), [term()], pos_integer()}

  @doc """
  Build the complete WHERE clause of `plan` for a branch. Returns
  `{where_sql, params, next_idx}`. Given a schema instead of a branch, it
  builds the WHERE of the plan's first element type.
  """
  @spec build_where(Plan.t(), Schema.t() | Branch.t(), pos_integer()) :: acc()
  def build_where(plan, schema_or_branch, idx \\ 1)

  def build_where(%Plan{} = plan, %Schema{} = schema, idx) do
    type = List.first(plan.element_types) || :node
    build_where(plan, Branch.resolve(type, schema, Branch.rank(plan, type)), idx)
  end

  def build_where(%Plan{} = plan, %Branch{schema: schema} = branch, idx) do
    {clauses, params, next_idx} =
      {[], [], idx}
      |> maybe_add_spatial(plan.spatial_filter, branch)
      |> add_spatial_filters(plan.spatial_filters, branch)
      |> maybe_add_spatial(plan.scope_geometry, branch)
      |> maybe_add_osm_ids(plan.osm_ids, branch)
      |> add_tag_filters(plan.tag_filters, branch)
      |> add_metadata_filters(plan.metadata_filters, branch)
      |> add_filter_exprs(plan.filter_exprs, schema)
      |> maybe_add_boundary(branch)
      |> maybe_add_h3_tiles(plan.caller_context, branch)
      |> maybe_add_partitions(plan.caller_context, branch)
      |> maybe_add_seek(plan, branch)
      |> add_custom_clauses(plan.custom_clauses, branch)

    case clauses do
      [] -> {"", params, next_idx}
      _ -> {"WHERE " <> Enum.join(Enum.reverse(clauses), " AND "), params, next_idx}
    end
  end

  defp push({clauses, params, _idx}, sql, new_params, next_idx),
    do: {[sql | clauses], params ++ new_params, next_idx}

  # ── Spatial filters ──────────────────────────────────────────────

  defp add_spatial_filters(acc, filters, branch),
    do: Enum.reduce(filters, acc, &maybe_add_spatial(&2, &1, branch))

  defp maybe_add_spatial(acc, nil, _branch), do: acc

  defp maybe_add_spatial({_, _, idx} = acc, spatial, branch) do
    {sql, new_params, next_idx} = spatial_filter_sql(spatial, branch, idx)
    push(acc, sql, new_params, next_idx)
  end

  defp spatial_filter_sql({:bbox, south, west, north, east}, %Branch{schema: schema}, idx)
       when west > east do
    # Antimeridian crossing: two envelopes
    geom = schema.columns.geometry
    srid = schema.srid

    sql =
      "(#{geom} && ST_MakeEnvelope($#{idx}, $#{idx + 1}, 180, $#{idx + 2}, #{srid})" <>
        " OR #{geom} && ST_MakeEnvelope(-180, $#{idx + 3}, $#{idx + 4}, $#{idx + 5}, #{srid}))"

    {sql, [west, south, north, south, east, north], idx + 6}
  end

  defp spatial_filter_sql({:bbox, south, west, north, east}, %Branch{schema: schema}, idx) do
    geom = schema.columns.geometry
    srid = schema.srid
    sql = "#{geom} && ST_MakeEnvelope($#{idx}, $#{idx + 1}, $#{idx + 2}, $#{idx + 3}, #{srid})"
    {sql, [west, south, east, north], idx + 4}
  end

  defp spatial_filter_sql({:around, lat, lng, radius}, %Branch{schema: schema}, idx) do
    geom = schema.columns.geometry
    srid = schema.srid

    sql =
      "ST_DWithin(#{geom}::geography, ST_Point($#{idx}, $#{idx + 1}, #{srid})::geography, $#{idx + 2})"

    {sql, [lng, lat, radius], idx + 3}
  end

  # Rows whose geometry fits no single cell have a NULL tile id on sparse
  # sources; they are matched geometrically against the cell instead.
  defp spatial_filter_sql({:h3, cell}, %Branch{sparse_tile_id?: true} = branch, idx) do
    tile_id = tile_column!(branch, "h3 filter")
    geom = branch.schema.columns.geometry

    {"(#{tile_id} <@ $#{idx}::h3index OR #{tile_id} @> $#{idx}::h3index OR (#{tile_id} IS NULL AND ST_Intersects(#{geom}, h3_cell_to_boundary_geometry($#{idx}::h3index))))",
     [cell], idx + 1}
  end

  defp spatial_filter_sql({:h3, cell}, branch, idx) do
    tile_id = tile_column!(branch, "h3 filter")
    sql = "(#{tile_id} <@ $#{idx}::h3index OR #{tile_id} @> $#{idx}::h3index)"
    {sql, [cell], idx + 1}
  end

  # A ring of {lng, lat} points, closed if it isn't already.
  defp spatial_filter_sql({:polygon, coords}, %Branch{schema: schema}, idx) do
    geom = schema.columns.geometry
    srid = schema.srid
    wkt = polygon_to_wkt(coords)
    {"ST_Within(#{geom}, ST_GeomFromText($#{idx}, #{srid}))", [wkt], idx + 1}
  end

  # Within `radius` meters of any geometry of a resolved set. The bounding-box
  # prefilter can use the geometry index: the reference is expanded by the
  # radius in degrees, over-estimated (a latitude degree is at least ~110.5
  # km, and longitude degrees shrink by cos(latitude) at the reference's
  # highest |latitude|, floored near the poles). Over-expanding only lets more
  # rows reach ST_DWithin, which decides.
  defp spatial_filter_sql({:around_set_resolved, ewkts, radius}, %Branch{schema: schema}, idx) do
    geom = schema.columns.geometry
    collection = build_geometry_collection_wkt(ewkts, schema.srid)

    sql =
      "#{geom} && ST_Expand(ST_GeomFromEWKT($#{idx}), $#{idx + 1} / GREATEST(cos(radians(LEAST(89.0, " <>
        "GREATEST(abs(ST_YMin(ST_GeomFromEWKT($#{idx + 2}))), abs(ST_YMax(ST_GeomFromEWKT($#{idx + 3}))))))), 0.01))" <>
        " AND ST_DWithin(#{geom}::geography, ST_GeomFromEWKT($#{idx + 4})::geography, $#{idx + 5})"

    {sql, [collection, radius / 110_000.0, collection, collection, collection, radius], idx + 6}
  end

  defp spatial_filter_sql({:predicate, predicate, geometry}, branch, idx),
    do: spatial_filter_sql({:predicate, predicate, geometry, nil}, branch, idx)

  defp spatial_filter_sql({:predicate, predicate, {:set_ref, name}, _radius}, _branch, _idx) do
    raise NotCompilable,
      reason: :unresolved_geometry_ref,
      message:
        ".#{predicate}() references set #{inspect(name)}, which must be resolved by the executor before SQL generation"
  end

  # Within `radius` meters of the geometry.
  defp spatial_filter_sql({:predicate, :around, geometry, radius}, %Branch{schema: schema}, idx)
       when is_number(radius) do
    geom = schema.columns.geometry
    ewkt = geometry_to_ewkt(geometry, schema.srid)

    {"ST_DWithin(#{geom}::geography, ST_GeomFromEWKT($#{idx})::geography, $#{idx + 1})",
     [ewkt, radius], idx + 2}
  end

  defp spatial_filter_sql({:predicate, :around, geometry, nil}, branch, idx),
    do: spatial_filter_sql({:predicate, :intersects, geometry, nil}, branch, idx)

  # Other predicates; with a radius the reference geometry is buffered by it.
  defp spatial_filter_sql({:predicate, predicate, geometry, radius}, %Branch{schema: schema}, idx) do
    geom_col = schema.columns.geometry
    ewkt = geometry_to_ewkt(geometry, schema.srid)
    {st_func, negated} = predicate_to_st(predicate)
    not_sql = if negated, do: "NOT ", else: ""

    case radius do
      nil ->
        {"#{not_sql}#{st_func}(#{geom_col}, ST_GeomFromEWKT($#{idx}))", [ewkt], idx + 1}

      radius when is_number(radius) ->
        {"#{not_sql}#{st_func}(#{geom_col}, ST_Buffer(ST_GeomFromEWKT($#{idx})::geography, $#{idx + 1})::geometry)",
         [ewkt, radius], idx + 2}
    end
  end

  defp spatial_filter_sql(other, _branch, _idx) do
    raise NotCompilable,
      reason: :unresolved_spatial_filter,
      message:
        "spatial filter #{inspect(other)} must be resolved by the executor before SQL generation"
  end

  defp tile_column!(%Branch{schema: schema}, what),
    do: schema.columns.tile_id || raise(ArgumentError, "tile_id column required for #{what}")

  # ── OSM IDs (element tables only) ───────────────────────────────

  defp maybe_add_osm_ids(acc, ids, _branch) when ids in [nil, []], do: acc
  defp maybe_add_osm_ids(acc, _ids, %Branch{element?: false}), do: acc

  defp maybe_add_osm_ids({_, _, idx} = acc, ids, %Branch{schema: schema}) do
    push(acc, "#{schema.columns.id} = ANY($#{idx})", [ids], idx + 1)
  end

  # ── Tag filters ──────────────────────────────────────────────────

  defp add_tag_filters(acc, filters, branch) do
    Enum.reduce(filters, acc, fn filter, {_, _, i} = acc ->
      {sql, new_params, next_i} = tag_filter_sql(filter, branch, i)
      push(acc, sql, new_params, next_i)
    end)
  end

  # `key: *` — the key exists.
  defp tag_filter_sql({:eq, key, "*"}, branch, idx),
    do: tag_filter_sql({:exists, key}, branch, idx)

  # Typed JSON values: the string form or the number/boolean it spells, each
  # a containment check a GIN index on the column can serve.
  defp tag_filter_sql({:eq, key, value}, %Branch{typed_values?: true} = branch, idx) do
    col = filter_col(branch)

    {sqls, next_idx} =
      value
      |> json_equivalents()
      |> Enum.map_reduce(idx, fn _form, i -> {"#{col} @> $#{i}::jsonb", i + 1} end)

    params = Enum.map(json_equivalents(value), &%{key => &1})
    {"(" <> Enum.join(sqls, " OR ") <> ")", params, next_idx}
  end

  defp tag_filter_sql({:eq, key, value}, branch, idx) do
    tags = filter_col(branch)
    sql = "#{tags} ? $#{idx} AND #{tags}->>$#{idx + 1} = $#{idx + 2}"
    {sql, [key, key, value], idx + 3}
  end

  defp tag_filter_sql({:neq, key, value}, branch, idx) do
    tags = filter_col(branch)
    sql = "(#{tags}->>$#{idx} != $#{idx + 1} OR NOT #{tags} ? $#{idx + 2})"
    {sql, [key, value, key], idx + 3}
  end

  defp tag_filter_sql({:exists, key}, branch, idx) do
    {"#{filter_col(branch)} ? $#{idx}", [key], idx + 1}
  end

  defp tag_filter_sql({:not_exists, key}, branch, idx) do
    {"NOT #{filter_col(branch)} ? $#{idx}", [key], idx + 1}
  end

  defp tag_filter_sql({:regex, key, pattern}, branch, idx) do
    {"#{filter_col(branch)}->>$#{idx} ~ $#{idx + 1}", [key, pattern], idx + 2}
  end

  defp tag_filter_sql({:regex_i, key, pattern}, branch, idx) do
    {"#{filter_col(branch)}->>$#{idx} ~* $#{idx + 1}", [key, pattern], idx + 2}
  end

  defp tag_filter_sql({:not_regex, key, pattern}, branch, idx) do
    tags = filter_col(branch)

    {"NOT (#{tags} ? $#{idx} AND #{tags}->>$#{idx + 1} ~ $#{idx + 2})", [key, key, pattern],
     idx + 3}
  end

  defp tag_filter_sql({:any_of, key, values}, branch, idx) do
    tags = filter_col(branch)

    {"#{tags} ? $#{idx} AND #{tags}->>$#{idx + 1} = ANY($#{idx + 2}::text[])", [key, key, values],
     idx + 3}
  end

  defp tag_filter_sql(:impossible, _branch, idx) do
    {"FALSE", [], idx}
  end

  defp tag_filter_sql({:is_in, name}, %Branch{schema: schema}, idx) do
    admin_table =
      schema.tables.admin_boundaries ||
        raise ArgumentError, "admin_boundaries table required for is_in filter"

    geom = schema.columns.geometry

    {"EXISTS (SELECT 1 FROM #{admin_table} ab WHERE ab.name = $#{idx} AND ST_Contains(ab.geom, #{geom}))",
     [name], idx + 1}
  end

  defp tag_filter_sql({:key_value_regex, key_pattern, val_pattern}, branch, idx) do
    {"EXISTS (SELECT 1 FROM jsonb_each_text(#{filter_col(branch)}) AS kv WHERE kv.key ~ $#{idx} AND kv.value ~ $#{idx + 1})",
     [key_pattern, val_pattern], idx + 2}
  end

  defp tag_filter_sql({:key_regex_exists, key_pattern}, branch, idx) do
    {"EXISTS (SELECT 1 FROM jsonb_object_keys(#{filter_col(branch)}) AS k WHERE k ~ $#{idx})",
     [key_pattern], idx + 1}
  end

  defp tag_filter_sql({:bracket_eq, _key, set_name, attr}, _branch, _idx) do
    raise NotCompilable,
      reason: :unresolved_attribute_ref,
      message:
        "$#{set_name}[#{attr}] must be resolved to its values by the executor before SQL generation"
  end

  defp filter_col(%Branch{schema: schema}), do: Schema.filter_tags_column(schema)

  # JSON values a filter string should match: itself, plus the number or
  # boolean it spells (`"5"` also matches `5`, `"true"` also `true`). Only a
  # typed form that prints back to exactly the filter string is added, so
  # "05", "5.0" or "1e3" match only the string itself.
  defp json_equivalents(value) when not is_binary(value), do: [value]
  defp json_equivalents(value) when value in ["true", "false"], do: [value, value == "true"]

  defp json_equivalents(value) do
    case typed_form(value) do
      nil -> [value]
      typed -> [value, typed]
    end
  end

  defp typed_form(value) do
    case Integer.parse(value) do
      {int, ""} -> if Integer.to_string(int) == value, do: int
      _ -> float_form(value)
    end
  end

  defp float_form(value) do
    case Float.parse(value) do
      {float, ""} -> if :json.encode(float) |> IO.iodata_to_binary() == value, do: float
      _ -> nil
    end
  end

  # ── Metadata filters (element tables only) ──────────────────────

  defp add_metadata_filters(acc, _filters, %Branch{element?: false}), do: acc

  defp add_metadata_filters(acc, filters, _branch) do
    Enum.reduce(filters, acc, fn filter, {_, _, i} = acc ->
      {sql, new_params, next_i} = metadata_filter_sql(filter, i)
      push(acc, sql, new_params, next_i)
    end)
  end

  defp metadata_filter_sql({:newer, %DateTime{} = dt}, idx) do
    {"updated_at >= $#{idx}", [dt], idx + 1}
  end

  defp metadata_filter_sql({:version, v}, idx) do
    {"version = $#{idx}", [v], idx + 1}
  end

  defp metadata_filter_sql({:changeset, c}, idx) do
    {"changeset = $#{idx}", [c], idx + 1}
  end

  # ── Filter expressions ──────────────────────────────────────────

  defp add_filter_exprs(acc, exprs, schema) do
    Enum.reduce(exprs, acc, fn expr, {_, _, i} = acc ->
      {sql, new_params, next_i} = Expression.to_sql(expr, schema, i)
      push(acc, sql, new_params, next_i)
    end)
  end

  # ── Boundary filter ─────────────────────────────────────────────

  # `boundary` elements are relations with a boundary tag.
  defp maybe_add_boundary({clauses, params, idx}, %Branch{name: :boundary, schema: schema}),
    do: {["#{schema.columns.tags} ? 'boundary'" | clauses], params, idx}

  defp maybe_add_boundary(acc, _branch), do: acc

  # ── H3 tile filter (from caller_context) ────────────────────────

  defp maybe_add_h3_tiles(acc, %{h3_tiles: tiles}, %Branch{schema: schema} = branch)
       when is_list(tiles) and tiles != [] do
    if length(tiles) > schema.limits.max_h3_tiles do
      # Too many cells for a useful prefilter; the spatial filter decides.
      acc
    else
      tile_col = tile_column!(branch, "h3 tile filter")
      {_, _, idx} = acc

      {tile_clauses, tile_params, next_idx} =
        Enum.reduce(tiles, {[], [], idx}, fn tile, {cls, ps, i} ->
          clause = "(#{tile_col} <@ $#{i}::h3index OR #{tile_col} @> $#{i}::h3index)"
          {[clause | cls], ps ++ [tile], i + 1}
        end)

      tiles_sql = Enum.join(Enum.reverse(tile_clauses), " OR ")

      sql =
        if branch.sparse_tile_id?,
          do: "(#{tile_col} IS NULL OR #{tiles_sql})",
          else: "(#{tiles_sql})"

      push(acc, sql, tile_params, next_idx)
    end
  end

  defp maybe_add_h3_tiles(acc, _context, _branch), do: acc

  # ── Partition filter (from caller_context) ──────────────────────

  defp maybe_add_partitions(_acc, %{partitions: [_ | _]}, %Branch{
         schema: %Schema{columns: %{partition_tile_id: nil}}
       }),
       do: raise(ArgumentError, "partition_tile_id column required for partition filter")

  defp maybe_add_partitions(acc, %{partitions: parts}, %Branch{partitioned?: true} = branch) do
    case partitions_for(parts, branch) do
      list when is_list(list) and list != [] ->
        {_, _, idx} = acc
        col = branch.schema.columns.partition_tile_id
        push(acc, "#{col} = ANY($#{idx}::bigint[])", [list], idx + 1)

      _ ->
        acc
    end
  end

  defp maybe_add_partitions(acc, _context, _branch), do: acc

  defp partitions_for(parts, _branch) when is_list(parts), do: parts
  defp partitions_for(parts, %Branch{name: name}) when is_map(parts), do: Map.get(parts, name)

  # ── Keyset pagination ───────────────────────────────────────────

  defp maybe_add_seek(acc, %Plan{seek: nil}, _branch), do: acc

  defp maybe_add_seek({_, _, idx} = acc, %Plan{seek: position} = plan, branch) do
    case Sort.seek(Sort.spec(plan, branch), branch, position, idx) do
      {nil, _params, _idx} -> acc
      {sql, params, next_idx} -> push(acc, sql, params, next_idx)
    end
  end

  # ── Custom clauses ──────────────────────────────────────────────

  defp add_custom_clauses(acc, custom, branch) do
    Enum.reduce(custom, acc, fn
      {sql_frag, frag_params}, acc ->
        add_custom_clause(acc, sql_frag, frag_params)

      {only, sql_frag, frag_params}, acc ->
        if only == branch.name, do: add_custom_clause(acc, sql_frag, frag_params), else: acc
    end)
  end

  defp add_custom_clause({_, _, i} = acc, sql_frag, frag_params) do
    # Rebase $N references in custom clauses to start at current idx
    push(acc, rebase_params(sql_frag, i), frag_params, i + length(frag_params))
  end

  defp rebase_params(sql, offset) when offset == 1, do: sql

  defp rebase_params(sql, offset) do
    # One pass, so a rebased $N is never rebased again.
    Regex.replace(~r/\$(\d+)/, sql, fn _, n -> "$#{String.to_integer(n) + offset - 1}" end)
  end

  # ── Geometry helpers ────────────────────────────────────────────

  defp geometry_to_ewkt({:ewkt, ewkt}, _srid) when is_binary(ewkt), do: ewkt

  defp geometry_to_ewkt({:point, lng, lat}, srid) do
    "SRID=#{srid};POINT(#{lng} #{lat})"
  end

  defp geometry_to_ewkt({:polygon, rings}, srid),
    do: PlazaQL.GeometryRef.polygon_ewkt(rings, srid)

  defp geometry_to_ewkt({:linestring, coords}, srid) do
    coords_str = Enum.map_join(coords, ", ", fn {lng, lat} -> "#{lng} #{lat}" end)
    "SRID=#{srid};LINESTRING(#{coords_str})"
  end

  # Coords are {lng, lat} tuples (matching geometry_to_ewkt convention).
  # WKT format is "lng lat" — longitude first.
  defp polygon_to_wkt(coords) do
    ring = Enum.map_join(coords, ", ", fn {lng, lat} -> "#{lng} #{lat}" end)
    {first_lng, first_lat} = hd(coords)
    {last_lng, last_lat} = List.last(coords)

    if first_lng == last_lng and first_lat == last_lat do
      "POLYGON((#{ring}))"
    else
      "POLYGON((#{ring}, #{first_lng} #{first_lat}))"
    end
  end

  defp build_geometry_collection_wkt(ewkts, srid) do
    geoms =
      Enum.map_join(ewkts, ", ", fn ewkt ->
        String.replace(ewkt, ~r/^SRID=\d+;/, "")
      end)

    "SRID=#{srid};GEOMETRYCOLLECTION(#{geoms})"
  end

  # `within` includes the boundary: an element on the edge of the area is in it.
  defp predicate_to_st(:within), do: {"ST_CoveredBy", false}
  defp predicate_to_st(:intersects), do: {"ST_Intersects", false}
  defp predicate_to_st(:contains), do: {"ST_Contains", false}
  defp predicate_to_st(:crosses), do: {"ST_Crosses", false}
  defp predicate_to_st(:touches), do: {"ST_Touches", false}
  defp predicate_to_st(:not_within), do: {"ST_CoveredBy", true}
  defp predicate_to_st(:not_intersects), do: {"ST_Intersects", true}
  defp predicate_to_st(:not_contains), do: {"ST_Contains", true}
end
