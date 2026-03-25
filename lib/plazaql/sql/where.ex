defmodule PlazaQL.SQL.Where do
  @moduledoc false
  # Internal: builds WHERE clause conditions from Plan filters.

  alias PlazaQL.Plan
  alias PlazaQL.Schema
  alias PlazaQL.SQL.Expression

  @type acc :: {String.t(), [term()], pos_integer()}

  @doc "Build the complete WHERE clause from a plan. Returns {where_sql, params, next_idx}."
  @spec build_where(Plan.t(), Schema.t(), pos_integer()) :: acc()
  def build_where(plan, schema, idx \\ 1)

  def build_where(%Plan{} = plan, %Schema{} = schema, idx) do
    acc = {[], [], idx}

    {clauses, params, next_idx} =
      acc
      |> maybe_add_spatial(plan.spatial_filter, schema)
      |> maybe_add_spatial(plan.scope_geometry, schema)
      |> maybe_add_osm_ids(plan.osm_ids, schema)
      |> add_tag_filters(plan.tag_filters, schema)
      |> add_metadata_filters(plan.metadata_filters, schema)
      |> add_filter_exprs(plan.filter_exprs, schema)
      |> maybe_add_boundary(plan.element_types, schema)
      |> maybe_add_h3_tiles(plan.caller_context, schema)
      |> maybe_add_partitions(plan.caller_context, schema)
      |> add_custom_clauses(plan.custom_clauses)

    case clauses do
      [] -> {"", params, next_idx}
      _ -> {"WHERE " <> Enum.join(Enum.reverse(clauses), " AND "), params, next_idx}
    end
  end

  # ── Spatial filters ──────────────────────────────────────────────

  defp maybe_add_spatial(acc, nil, _schema), do: acc

  defp maybe_add_spatial({clauses, params, idx}, spatial, schema) do
    {sql, new_params, next_idx} = spatial_filter_sql(spatial, schema, idx)
    {[sql | clauses], params ++ new_params, next_idx}
  end

  defp spatial_filter_sql({:bbox, south, west, north, east}, schema, idx) when west > east do
    geom = schema.columns.geometry
    srid = schema.srid

    sql =
      "(#{geom} && ST_MakeEnvelope($#{idx}, $#{idx + 1}, 180, $#{idx + 2}, #{srid})" <>
        " OR #{geom} && ST_MakeEnvelope(-180, $#{idx + 3}, $#{idx + 4}, $#{idx + 5}, #{srid}))"

    {sql, [west, south, north, south, east, north], idx + 6}
  end

  defp spatial_filter_sql({:bbox, south, west, north, east}, schema, idx) do
    geom = schema.columns.geometry
    srid = schema.srid
    sql = "#{geom} && ST_MakeEnvelope($#{idx}, $#{idx + 1}, $#{idx + 2}, $#{idx + 3}, #{srid})"
    {sql, [west, south, east, north], idx + 4}
  end

  defp spatial_filter_sql({:around, lat, lng, radius}, schema, idx) do
    geom = schema.columns.geometry
    srid = schema.srid

    sql =
      "ST_DWithin(#{geom}::geography, ST_Point($#{idx}, $#{idx + 1}, #{srid})::geography, $#{idx + 2})"

    {sql, [lng, lat, radius], idx + 3}
  end

  defp spatial_filter_sql({:h3, cell}, schema, idx) do
    tile_id =
      schema.columns.tile_id ||
        raise ArgumentError, "tile_id column required for h3 filter"

    sql = "(#{tile_id} <@ $#{idx}::h3index OR #{tile_id} @> $#{idx}::h3index)"
    {sql, [cell], idx + 1}
  end

  defp spatial_filter_sql({:polygon, coords}, schema, idx) do
    geom = schema.columns.geometry
    srid = schema.srid
    wkt = polygon_to_wkt(coords)
    {"ST_Within(#{geom}, ST_GeomFromText($#{idx}, #{srid}))", [wkt], idx + 1}
  end

  defp spatial_filter_sql({:around_set_resolved, ewkts, radius}, schema, idx) do
    geom = schema.columns.geometry
    collection_wkt = build_geometry_collection_wkt(ewkts, schema.srid)

    {"ST_DWithin(#{geom}::geography, ST_GeomFromEWKT($#{idx})::geography, $#{idx + 1})",
     [collection_wkt, radius], idx + 2}
  end

  defp spatial_filter_sql({:predicate, predicate, geometry}, schema, idx) do
    geom_col = schema.columns.geometry
    ewkt = geometry_to_ewkt(geometry, schema.srid)

    {st_func, negated} = predicate_to_st(predicate)

    sql =
      if negated do
        "NOT #{st_func}(#{geom_col}, ST_GeomFromEWKT($#{idx}))"
      else
        "#{st_func}(#{geom_col}, ST_GeomFromEWKT($#{idx}))"
      end

    {sql, [ewkt], idx + 1}
  end

  # ── OSM IDs ──────────────────────────────────────────────────────

  defp maybe_add_osm_ids(acc, nil, _schema), do: acc
  defp maybe_add_osm_ids(acc, [], _schema), do: acc

  defp maybe_add_osm_ids({clauses, params, idx}, ids, schema) do
    id_col = schema.columns.id
    sql = "#{id_col} = ANY($#{idx})"
    {[sql | clauses], params ++ [ids], idx + 1}
  end

  # ── Tag filters ──────────────────────────────────────────────────

  defp add_tag_filters(acc, [], _schema), do: acc

  defp add_tag_filters({clauses, params, idx}, filters, schema) do
    Enum.reduce(filters, {clauses, params, idx}, fn filter, {cls, ps, i} ->
      {sql, new_params, next_i} = tag_filter_sql(filter, schema, i)
      {[sql | cls], ps ++ new_params, next_i}
    end)
  end

  defp tag_filter_sql({:eq, key, value}, schema, idx) do
    tags = schema.columns.tags
    sql = "#{tags} ? $#{idx} AND #{tags}->>$#{idx + 1} = $#{idx + 2}"
    {sql, [key, key, value], idx + 3}
  end

  defp tag_filter_sql({:neq, key, value}, schema, idx) do
    tags = schema.columns.tags
    sql = "(#{tags}->>$#{idx} != $#{idx + 1} OR NOT #{tags} ? $#{idx + 2})"
    {sql, [key, value, key], idx + 3}
  end

  defp tag_filter_sql({:exists, key}, schema, idx) do
    tags = schema.columns.tags
    {"#{tags} ? $#{idx}", [key], idx + 1}
  end

  defp tag_filter_sql({:not_exists, key}, schema, idx) do
    tags = schema.columns.tags
    {"NOT #{tags} ? $#{idx}", [key], idx + 1}
  end

  defp tag_filter_sql({:regex, key, pattern}, schema, idx) do
    tags = schema.columns.tags
    {"#{tags}->>$#{idx} ~ $#{idx + 1}", [key, pattern], idx + 2}
  end

  defp tag_filter_sql({:regex_i, key, pattern}, schema, idx) do
    tags = schema.columns.tags
    {"#{tags}->>$#{idx} ~* $#{idx + 1}", [key, pattern], idx + 2}
  end

  defp tag_filter_sql({:not_regex, key, pattern}, schema, idx) do
    tags = schema.columns.tags

    {"NOT (#{tags} ? $#{idx} AND #{tags}->>$#{idx + 1} ~ $#{idx + 2})", [key, key, pattern],
     idx + 3}
  end

  defp tag_filter_sql({:any_of, key, values}, schema, idx) do
    tags = schema.columns.tags

    {"#{tags} ? $#{idx} AND #{tags}->>$#{idx + 1} = ANY($#{idx + 2}::text[])", [key, key, values],
     idx + 3}
  end

  defp tag_filter_sql(:impossible, _schema, idx) do
    {"FALSE", [], idx}
  end

  defp tag_filter_sql({:is_in, name}, schema, idx) do
    admin_table =
      schema.tables.admin_boundaries ||
        raise ArgumentError, "admin_boundaries table required for is_in filter"

    geom = schema.columns.geometry

    {"EXISTS (SELECT 1 FROM #{admin_table} ab WHERE ab.name = $#{idx} AND ST_Contains(ab.geom, #{geom}))",
     [name], idx + 1}
  end

  defp tag_filter_sql({:key_value_regex, key_pattern, val_pattern}, schema, idx) do
    tags = schema.columns.tags

    {"EXISTS (SELECT 1 FROM jsonb_each_text(#{tags}) AS kv WHERE kv.key ~ $#{idx} AND kv.value ~ $#{idx + 1})",
     [key_pattern, val_pattern], idx + 2}
  end

  defp tag_filter_sql({:key_regex_exists, key_pattern}, schema, idx) do
    tags = schema.columns.tags

    {"EXISTS (SELECT 1 FROM jsonb_object_keys(#{tags}) AS k WHERE k ~ $#{idx})", [key_pattern],
     idx + 1}
  end

  defp tag_filter_sql({:bracket_eq, key, _set_name, _attr}, schema, idx) do
    tags = schema.columns.tags

    {"#{tags} ? $#{idx} AND #{tags}->>$#{idx + 1} = $#{idx + 2}", [key, key, "__bracket_ref__"],
     idx + 3}
  end

  # ── Metadata filters ────────────────────────────────────────────

  defp add_metadata_filters(acc, [], _schema), do: acc

  defp add_metadata_filters({clauses, params, idx}, filters, schema) do
    Enum.reduce(filters, {clauses, params, idx}, fn filter, {cls, ps, i} ->
      {sql, new_params, next_i} = metadata_filter_sql(filter, schema, i)
      {[sql | cls], ps ++ new_params, next_i}
    end)
  end

  defp metadata_filter_sql({:newer, %DateTime{} = dt}, _schema, idx) do
    {"updated_at >= $#{idx}", [dt], idx + 1}
  end

  defp metadata_filter_sql({:version, v}, _schema, idx) do
    {"version = $#{idx}", [v], idx + 1}
  end

  defp metadata_filter_sql({:changeset, c}, _schema, idx) do
    {"changeset = $#{idx}", [c], idx + 1}
  end

  # ── Filter expressions ──────────────────────────────────────────

  defp add_filter_exprs(acc, [], _schema), do: acc

  defp add_filter_exprs({clauses, params, idx}, exprs, schema) do
    Enum.reduce(exprs, {clauses, params, idx}, fn expr, {cls, ps, i} ->
      {sql, new_params, next_i} = Expression.to_sql(expr, schema, i)
      {[sql | cls], ps ++ new_params, next_i}
    end)
  end

  # ── Boundary filter ─────────────────────────────────────────────

  defp maybe_add_boundary(acc, element_types, schema) do
    if :boundary in element_types do
      {clauses, params, idx} = acc
      tags = schema.columns.tags
      {["#{tags} ? 'boundary'" | clauses], params, idx}
    else
      acc
    end
  end

  # ── H3 tile filter (from caller_context) ────────────────────────

  defp maybe_add_h3_tiles(acc, %{h3_tiles: tiles}, schema) when is_list(tiles) and tiles != [] do
    tile_col =
      schema.columns.tile_id ||
        raise ArgumentError, "tile_id column required for h3 tile filter"

    {clauses, params, idx} = acc

    {tile_clauses, tile_params, next_idx} =
      Enum.reduce(tiles, {[], [], idx}, fn tile, {cls, ps, i} ->
        clause = "(#{tile_col} <@ $#{i}::h3index OR #{tile_col} @> $#{i}::h3index)"
        {[clause | cls], ps ++ [tile], i + 1}
      end)

    sql =
      tile_clauses
      |> Enum.reverse()
      |> Enum.join(" OR ")
      |> then(&"(#{&1})")

    {[sql | clauses], params ++ tile_params, next_idx}
  end

  defp maybe_add_h3_tiles(acc, _context, _schema), do: acc

  # ── Partition filter (from caller_context) ──────────────────────

  defp maybe_add_partitions(acc, %{partitions: parts}, schema)
       when is_list(parts) and parts != [] do
    part_col =
      schema.columns.partition_tile_id ||
        raise ArgumentError, "partition_tile_id column required for partition filter"

    {clauses, params, idx} = acc
    sql = "#{part_col} = ANY($#{idx}::bigint[])"
    {[sql | clauses], params ++ [parts], idx + 1}
  end

  defp maybe_add_partitions(acc, _context, _schema), do: acc

  # ── Custom clauses ──────────────────────────────────────────────

  defp add_custom_clauses(acc, []), do: acc

  defp add_custom_clauses({clauses, params, idx}, custom) do
    Enum.reduce(custom, {clauses, params, idx}, fn {sql_frag, frag_params}, {cls, ps, i} ->
      # Rebase $N references in custom clauses to start at current idx
      rebased_sql = rebase_params(sql_frag, i)
      next_i = i + length(frag_params)
      {[rebased_sql | cls], ps ++ frag_params, next_i}
    end)
  end

  defp rebase_params(sql, offset) when offset == 1, do: sql

  defp rebase_params(sql, offset) do
    # Replace $N references (highest first to avoid $1 matching in $10)
    # Find all $N references, sort descending, replace each
    Regex.scan(~r/\$(\d+)/, sql)
    |> Enum.map(fn [_, n] -> String.to_integer(n) end)
    |> Enum.uniq()
    |> Enum.sort(:desc)
    |> Enum.reduce(sql, fn n, acc ->
      String.replace(acc, "$#{n}", "$#{n + offset - 1}")
    end)
  end

  # ── Geometry helpers ────────────────────────────────────────────

  defp geometry_to_ewkt({:point, lng, lat}, srid) do
    "SRID=#{srid};POINT(#{lng} #{lat})"
  end

  defp geometry_to_ewkt({:polygon, [ring | _]}, srid) do
    coords_str = Enum.map_join(ring, ", ", fn {lng, lat} -> "#{lng} #{lat}" end)
    "SRID=#{srid};POLYGON((#{coords_str}))"
  end

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
      Enum.map_join(ewkts, ",", fn ewkt ->
        String.replace(ewkt, ~r/^SRID=\d+;/, "")
      end)

    "SRID=#{srid};GEOMETRYCOLLECTION(#{geoms})"
  end

  defp predicate_to_st(:within), do: {"ST_Within", false}
  defp predicate_to_st(:intersects), do: {"ST_Intersects", false}
  defp predicate_to_st(:contains), do: {"ST_Contains", false}
  defp predicate_to_st(:crosses), do: {"ST_Crosses", false}
  defp predicate_to_st(:touches), do: {"ST_Touches", false}
  defp predicate_to_st(:not_within), do: {"ST_Within", true}
  defp predicate_to_st(:not_intersects), do: {"ST_Intersects", true}
  defp predicate_to_st(:not_contains), do: {"ST_Contains", true}
end
