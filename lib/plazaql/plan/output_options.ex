defmodule PlazaQL.Plan.OutputOptions do
  @moduledoc """
  Output formatting options for query results.

  Controls geometry transforms (simplify, buffer, centroid), coordinate
  precision, field selection, sort order, and extra includes. Set by
  method calls like `.simplify(100)`, `.centroid()`, `.fields("name", "amenity")`.
  """

  @type t :: %__MODULE__{
          simplify: float() | nil,
          buffer: float() | nil,
          precision: 1..15 | nil,
          centroid: boolean(),
          geometry: boolean(),
          fields: :all | [String.t()],
          include: MapSet.t(),
          sort: nil | :distance | :name | :osm_id | :qt
        }

  defstruct simplify: nil,
            buffer: nil,
            precision: nil,
            centroid: false,
            geometry: true,
            fields: :all,
            include: MapSet.new(),
            sort: nil
end
