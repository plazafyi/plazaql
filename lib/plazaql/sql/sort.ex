defmodule PlazaQL.SQL.Sort do
  @moduledoc false
  # Internal: a branch's sort — what rows are ordered by, the value each row
  # reports as `sort_key`, and the keyset condition that resumes after a row.
  #
  # Every row-returning branch has one total order: the sort (if any), then
  # the branch's key columns. Rows of several branches merge on
  # (sort value, branch rank, keys).

  alias PlazaQL.Plan
  alias PlazaQL.Plan.OutputOptions
  alias PlazaQL.Schema
  alias PlazaQL.SQL.Branch
  alias PlazaQL.SQL.Expression

  @typedoc "Builds a SQL fragment from the next free parameter index."
  @type fragment_fun :: (pos_integer() -> {String.t(), [term()], pos_integer()})

  @type t ::
          nil
          | %{
              key: fragment_fun(),
              order: fragment_fun(),
              dir: :asc | :desc,
              nulls: String.t(),
              keys_only?: boolean()
            }

  @doc "The branch's sort, or nil when the plan has no explicit sort."
  @spec spec(Plan.t(), Branch.t()) :: t()
  def spec(%Plan{sort_expr: {expr, dir}}, %Branch{schema: schema}) when expr != nil do
    fun = fn idx -> Expression.to_sql(expr, schema, idx) end
    %{key: fun, order: fun, dir: dir, nulls: "", keys_only?: false}
  end

  def spec(%Plan{output_options: %OutputOptions{sort: :osm_id}}, %Branch{keys: [key | _]}) do
    fun = fn idx -> {key, [], idx} end
    %{key: fun, order: fun, dir: :asc, nulls: "", keys_only?: true}
  end

  def spec(%Plan{output_options: %OutputOptions{sort: :name}}, %Branch{schema: schema}) do
    col = Schema.filter_tags_column(schema)
    fun = fn idx -> {~s|(#{col}->>'name') COLLATE "C"|, [], idx} end
    %{key: fun, order: fun, dir: :asc, nulls: " NULLS LAST", keys_only?: false}
  end

  def spec(%Plan{output_options: %OutputOptions{sort: :qt}}, %Branch{schema: schema}) do
    tile =
      schema.columns.tile_id || raise ArgumentError, "tile_id column required for qt sort"

    %{
      key: fn idx -> {"#{tile}::text", [], idx} end,
      order: fn idx -> {tile, [], idx} end,
      dir: :asc,
      nulls: "",
      keys_only?: false
    }
  end

  def spec(%Plan{output_options: %OutputOptions{sort: :distance}} = plan, %Branch{schema: schema}) do
    {lat, lng} =
      reference_point(plan) ||
        raise ArgumentError, "sort by distance needs an around filter on a point"

    geom = schema.columns.geometry
    srid = schema.srid

    fun = fn idx ->
      {"ST_Distance(#{geom}::geography, ST_Point($#{idx}, $#{idx + 1}, #{srid})::geography)",
       [lng, lat], idx + 2}
    end

    %{key: fun, order: fun, dir: :asc, nulls: "", keys_only?: false}
  end

  def spec(_plan, _branch), do: nil

  @doc """
  The `{lat, lng}` an around filter measures from: the first
  `{:around, lat, lng, r}` filter or `:around` predicate on a point.
  """
  @spec reference_point(Plan.t()) :: {number(), number()} | nil
  def reference_point(%Plan{spatial_filter: primary, spatial_filters: extras}) do
    Enum.find_value([primary | extras], fn
      {:around, lat, lng, _radius} -> {lat, lng}
      {:predicate, :around, {:point, lng, lat}} -> {lat, lng}
      {:predicate, :around, {:point, lng, lat}, _radius} -> {lat, lng}
      _ -> nil
    end)
  end

  @doc "ORDER BY: the sort, then the branch's keys (ascending)."
  @spec order_by(t(), Branch.t(), pos_integer()) :: {String.t(), [term()], pos_integer()}
  def order_by(nil, %Branch{keys: keys}, idx),
    do: {"ORDER BY " <> Enum.map_join(keys, ", ", &"#{&1} ASC"), [], idx}

  def order_by(%{keys_only?: true}, branch, idx), do: order_by(nil, branch, idx)

  def order_by(%{order: order, dir: dir, nulls: nulls}, %Branch{keys: keys}, idx) do
    {sql, params, next} = order.(idx)
    keys_sql = Enum.map_join(keys, ", ", &"#{&1} ASC")
    {"ORDER BY #{sql} #{direction(dir)}#{nulls}, #{keys_sql}", params, next}
  end

  @doc "The `sort_key` select column, when sorted."
  @spec key_column(t(), pos_integer()) :: {[String.t()], [term()], pos_integer()}
  def key_column(nil, idx), do: {[], [], idx}

  def key_column(%{key: key}, idx) do
    {sql, params, next} = key.(idx)
    {["#{sql} AS sort_key"], params, next}
  end

  @doc """
  The keyset condition: rows of this branch after position
  `{sort_value, rank, keys}` in (sort value, rank, keys) order. Nulls sort
  last ascending and first descending (Postgres' defaults).
  """
  @spec seek(t(), Branch.t(), Plan.seek(), pos_integer()) ::
          {String.t() | nil, [term()], pos_integer()}
  def seek(nil, %Branch{rank: rank}, {_sv, cursor_rank, _pk}, idx) when rank < cursor_rank,
    do: {"FALSE", [], idx}

  def seek(nil, %Branch{rank: rank} = branch, {_sv, rank, pk}, idx), do: keys_after(branch, pk, idx)
  def seek(nil, _branch, _position, idx), do: {nil, [], idx}

  def seek(spec, %Branch{rank: rank} = branch, {sv, cursor_rank, pk}, idx) do
    cond do
      rank > cursor_rank ->
        {after_sql, p1, i1} = value_after(spec, sv, idx)
        {same_sql, p2, i2} = value_equal(spec, sv, i1)
        {"(#{after_sql} OR #{same_sql})", p1 ++ p2, i2}

      rank < cursor_rank ->
        value_after(spec, sv, idx)

      true ->
        {after_sql, p1, i1} = value_after(spec, sv, idx)
        {same_sql, p2, i2} = value_equal(spec, sv, i1)
        {keys_sql, p3, i3} = keys_after(branch, pk, i2)
        {"(#{after_sql} OR (#{same_sql} AND #{keys_sql}))", p1 ++ p2 ++ p3, i3}
    end
  end

  defp value_after(%{dir: :asc}, nil, idx), do: {"FALSE", [], idx}

  defp value_after(%{dir: :asc, key: key}, sv, idx) do
    {k1, p1, i1} = key.(idx)
    {k2, p2, i2} = key.(i1 + 1)
    {"(#{k1} > $#{i1} OR #{k2} IS NULL)", p1 ++ [sv] ++ p2, i2}
  end

  defp value_after(%{dir: :desc, key: key}, nil, idx) do
    {k, p, i} = key.(idx)
    {"#{k} IS NOT NULL", p, i}
  end

  defp value_after(%{dir: :desc, key: key}, sv, idx) do
    {k, p, i} = key.(idx)
    {"#{k} < $#{i}", p ++ [sv], i + 1}
  end

  defp value_equal(%{key: key}, nil, idx) do
    {k, p, i} = key.(idx)
    {"#{k} IS NULL", p, i}
  end

  defp value_equal(%{key: key}, sv, idx) do
    {k, p, i} = key.(idx)
    {"#{k} = $#{i}", p ++ [sv], i + 1}
  end

  # Rows whose keys come after `pk`: a scalar for one key column, a tuple
  # compared as a row for several.
  defp keys_after(%Branch{keys: [key]}, pk, idx), do: {"#{key} > $#{idx}", [pk], idx + 1}

  defp keys_after(%Branch{keys: keys}, pk, idx)
       when is_tuple(pk) and tuple_size(pk) == length(keys) do
    values = Tuple.to_list(pk)
    placeholders = Enum.map_join(0..(length(keys) - 1), ", ", &"$#{idx + &1}")
    {"(#{Enum.join(keys, ", ")}) > (#{placeholders})", values, idx + length(keys)}
  end

  defp keys_after(%Branch{keys: keys}, pk, _idx),
    do: raise(ArgumentError, "seek keys #{inspect(pk)} don't match key columns #{inspect(keys)}")

  defp direction(:desc), do: "DESC"
  defp direction(_asc), do: "ASC"
end
