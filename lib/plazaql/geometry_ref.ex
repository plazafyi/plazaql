defmodule PlazaQL.GeometryRef do
  @moduledoc """
  Reference geometries used by `overlap_fraction(...)`, `.overlap_fraction(...)`,
  and spatial predicates (`.within(...)`, `.intersects(...)`, ...).

  A reference is either a literal polygon or a reference to a named set that the
  executor resolves at run time:

    * `{:polygon, [ring]}` — `ring` is a closed list of `{lng, lat}` tuples
      (GeoJSON order, first point == last point). Produced from
      `polygon(point(lat, lng), ...)` and `bbox(s, w, n, e)`.
    * `{:set_ref, name}` — `"name"` for `$name`, `"$$.name"` for `$$.name`.
  """

  @type ring :: [{number(), number()}]
  @type t :: {:polygon, [ring()]} | {:set_ref, String.t()}

  @doc """
  Convert a PlazaQL AST geometry argument into a reference geometry.

  Accepts `polygon(...)` with literal points (at least three), `bbox(s, w, n, e)`
  with literal numbers, `$var`, and `$$.name`. Returns `:error` for anything else.
  """
  @spec from_ast(term()) :: {:ok, t()} | :error
  def from_ast({:var_ref, "$$", _pos}), do: :error
  def from_ast({:var_ref, "$" <> name, _pos}), do: {:ok, {:set_ref, name}}
  def from_ast({:output_var_ref, name, _pos}), do: {:ok, {:set_ref, "$$." <> name}}

  def from_ast({:bbox, s, w, n, e, _pos})
      when is_number(s) and is_number(w) and is_number(n) and is_number(e) do
    {:ok, {:polygon, [bbox_ring(s, w, n, e)]}}
  end

  def from_ast({:polygon, items, _pos}) when is_list(items) do
    coords =
      Enum.map(items, fn
        {:point, lat, lng, _} when is_number(lat) and is_number(lng) -> {lng, lat}
        _ -> nil
      end)

    if Enum.any?(coords, &is_nil/1) or length(Enum.uniq(coords)) < 3 do
      :error
    else
      {:ok, {:polygon, [close_ring(coords)]}}
    end
  end

  def from_ast(_), do: :error

  @doc "Closed rectangle ring `[{w,s},{e,s},{e,n},{w,n},{w,s}]` for `bbox(s, w, n, e)`."
  @spec bbox_ring(number(), number(), number(), number()) :: ring()
  def bbox_ring(s, w, n, e), do: [{w, s}, {e, s}, {e, n}, {w, n}, {w, s}]

  @doc "Append the first coordinate when the ring is not already closed."
  @spec close_ring(ring()) :: ring()
  def close_ring([first | _] = coords) do
    if List.last(coords) == first, do: coords, else: coords ++ [first]
  end

  @doc "EWKT for a literal polygon reference."
  @spec polygon_ewkt([ring()], pos_integer()) :: String.t()
  def polygon_ewkt(rings, srid) do
    rings_str =
      Enum.map_join(rings, ", ", fn ring ->
        "(" <> Enum.map_join(ring, ", ", fn {lng, lat} -> "#{lng} #{lat}" end) <> ")"
      end)

    "SRID=#{srid};POLYGON(#{rings_str})"
  end
end
