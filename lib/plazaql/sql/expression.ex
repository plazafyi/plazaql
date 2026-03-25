defmodule PlazaQL.SQL.Expression do
  @moduledoc false
  # Internal: expression AST → SQL fragment with parameterized values.
  # Uses accumulator pattern: {fragment, params, next_idx}

  alias PlazaQL.Schema

  @type acc :: {String.t(), [term()], pos_integer()}

  @doc "Convert an expression AST node to a SQL fragment."
  @spec to_sql(term(), Schema.t(), pos_integer()) :: acc()
  def to_sql(expr, schema, idx \\ 1)

  # ── Binary operators ──────────────────────────────────────────────

  @binary_ops %{
    eq: "=",
    neq: "!=",
    gt: ">",
    lt: "<",
    gte: ">=",
    lte: "<=",
    add: "+",
    sub: "-",
    mul: "*"
  }

  for {op, sql_op} <- @binary_ops do
    def to_sql({:bin_op, unquote(op), left, right, _pos}, schema, idx) do
      {l_sql, l_params, idx2} = to_sql(left, schema, idx)
      {r_sql, r_params, idx3} = to_sql(right, schema, idx2)
      {"(#{l_sql} #{unquote(sql_op)} #{r_sql})", l_params ++ r_params, idx3}
    end
  end

  def to_sql({:bin_op, :and, left, right, _pos}, schema, idx) do
    {l_sql, l_params, idx2} = to_sql(left, schema, idx)
    {r_sql, r_params, idx3} = to_sql(right, schema, idx2)
    {"(#{l_sql} AND #{r_sql})", l_params ++ r_params, idx3}
  end

  def to_sql({:bin_op, :or, left, right, _pos}, schema, idx) do
    {l_sql, l_params, idx2} = to_sql(left, schema, idx)
    {r_sql, r_params, idx3} = to_sql(right, schema, idx2)
    {"(#{l_sql} OR #{r_sql})", l_params ++ r_params, idx3}
  end

  def to_sql({:bin_op, :div, left, right, _pos}, schema, idx) do
    {l_sql, l_params, idx2} = to_sql(left, schema, idx)
    {r_sql, r_params, idx3} = to_sql(right, schema, idx2)
    {"(#{l_sql} / NULLIF(#{r_sql}, 0))", l_params ++ r_params, idx3}
  end

  # ── Unary operators ───────────────────────────────────────────────

  def to_sql({:unary_op, :not, operand, _pos}, schema, idx) do
    {sql, params, next_idx} = to_sql(operand, schema, idx)
    {"NOT (#{sql})", params, next_idx}
  end

  def to_sql({:unary_op, :neg, operand, _pos}, schema, idx) do
    {sql, params, next_idx} = to_sql(operand, schema, idx)
    {"-(#{sql})", params, next_idx}
  end

  # ── Tag access ────────────────────────────────────────────────────

  def to_sql({:tag_access, key, _pos}, schema, idx) do
    col = schema.columns.tags
    {"#{col} ->> $#{idx}", [key], idx + 1}
  end

  # ── Property accessors ────────────────────────────────────────────

  def to_sql({:prop_access, :id, _pos}, schema, idx) do
    {schema.columns.id, [], idx}
  end

  def to_sql({:prop_access, :lat, _pos}, schema, idx) do
    geom = schema.columns.geometry
    {"ST_Y(#{geom})", [], idx}
  end

  def to_sql({:prop_access, :lon, _pos}, schema, idx) do
    geom = schema.columns.geometry
    {"ST_X(#{geom})", [], idx}
  end

  def to_sql({:prop_access, :type, _pos}, _schema, _idx) do
    raise ArgumentError, "type property cannot be converted to SQL"
  end

  # ── Geometry functions ────────────────────────────────────────────

  def to_sql({:geom_func, :length, _pos}, schema, idx) do
    geom = schema.columns.geometry
    {"ST_Length(#{geom}::geography)", [], idx}
  end

  def to_sql({:geom_func, :area, _pos}, schema, idx) do
    geom = schema.columns.geometry
    {"ST_Area(#{geom}::geography)", [], idx}
  end

  def to_sql({:geom_func, :is_closed, _pos}, schema, idx) do
    geom = schema.columns.geometry
    {"ST_IsClosed(#{geom})", [], idx}
  end

  def to_sql({:geom_func, :distance, {lat, lng}, _pos}, schema, idx) do
    geom = schema.columns.geometry
    srid = schema.srid

    sql =
      "ST_Distance(ST_Centroid(#{geom})::geography, ST_SetSRID(ST_MakePoint($#{idx}, $#{idx + 1}), #{srid})::geography)"

    {sql, [lng, lat], idx + 2}
  end

  def to_sql({:geom_func, :elevation, _pos}, schema, idx) do
    geom = schema.columns.geometry
    elev = schema.elevation_table

    if is_nil(elev) do
      raise ArgumentError, "elevation_table must be set in schema for elevation expressions"
    end

    sql =
      "(SELECT ST_Value(r.rast, ST_Centroid(#{geom}), true) FROM #{elev} r WHERE ST_Intersects(r.rast, ST_Centroid(#{geom})) LIMIT 1)"

    {sql, [], idx}
  end

  # ── Type coercion ─────────────────────────────────────────────────

  def to_sql({:coerce_func, :number, arg, _pos}, schema, idx) do
    {arg_sql, params, next_idx} = to_sql(arg, schema, idx)
    {"(#{arg_sql})::numeric", params, next_idx}
  end

  def to_sql({:coerce_func, :is_number, arg, _pos}, schema, idx) do
    {arg_sql, params, next_idx} = to_sql(arg, schema, idx)
    {"#{arg_sql} ~ $#{next_idx}", params ++ ["^-?[0-9]+(\\.[0-9]+)?$"], next_idx + 1}
  end

  # ── String functions ──────────────────────────────────────────────

  def to_sql({:str_func, :starts_with, arg1, arg2, _pos}, schema, idx) do
    {a1_sql, a1_params, idx2} = to_sql(arg1, schema, idx)
    {a2_sql, a2_params, idx3} = to_sql(arg2, schema, idx2)
    escaped = "replace(replace(replace(#{a2_sql}::text, '\\', '\\\\'), '%', '\\%'), '_', '\\_')"
    {"#{a1_sql} LIKE #{escaped} || '%'", a1_params ++ a2_params, idx3}
  end

  def to_sql({:str_func, :ends_with, arg1, arg2, _pos}, schema, idx) do
    {a1_sql, a1_params, idx2} = to_sql(arg1, schema, idx)
    {a2_sql, a2_params, idx3} = to_sql(arg2, schema, idx2)
    escaped = "replace(replace(replace(#{a2_sql}::text, '\\', '\\\\'), '%', '\\%'), '_', '\\_')"
    {"#{a1_sql} LIKE '%' || #{escaped}", a1_params ++ a2_params, idx3}
  end

  def to_sql({:str_func, :str_contains, arg1, arg2, _pos}, schema, idx) do
    {a1_sql, a1_params, idx2} = to_sql(arg1, schema, idx)
    {a2_sql, a2_params, idx3} = to_sql(arg2, schema, idx2)
    escaped = "replace(replace(replace(#{a2_sql}::text, '\\', '\\\\'), '%', '\\%'), '_', '\\_')"
    {"#{a1_sql} LIKE '%' || #{escaped} || '%'", a1_params ++ a2_params, idx3}
  end

  def to_sql({:str_func, :size, arg, nil, _pos}, schema, idx) do
    {arg_sql, params, next_idx} = to_sql(arg, schema, idx)
    {"char_length(#{arg_sql})", params, next_idx}
  end

  # ── Literals ──────────────────────────────────────────────────────

  def to_sql({:number, n, _pos}, _schema, idx) do
    {"$#{idx}", [n], idx + 1}
  end

  def to_sql({:string, s, _pos}, _schema, idx) do
    {"$#{idx}", [s], idx + 1}
  end

  def to_sql({:bool, true, _pos}, _schema, idx), do: {"TRUE", [], idx}
  def to_sql({:bool, false, _pos}, _schema, idx), do: {"FALSE", [], idx}

  # ── Fallback ──────────────────────────────────────────────────────

  def to_sql(node, _schema, _idx) do
    raise ArgumentError, "unhandled expression node in SQL generation: #{inspect(node)}"
  end
end
