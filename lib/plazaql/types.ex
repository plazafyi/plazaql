defmodule PlazaQL.Types do
  @moduledoc """
  Type definitions and helpers for PlazaQL type checking.

  Defines the PlazaQL type hierarchy, method phase ordering, and type compatibility rules.
  """

  @type pql_type ::
          :point
          | :linestring
          | :polygon
          | :point_set
          | :line_set
          | :polygon_set
          | :geo_set
          | :geo_element
          | :value_set
          | :route
          | :isochrone
          | :boundary
          | :matrix
          | :elevation
          | :grouped_set
          | :scalar

  @geometry_types [:point, :linestring, :polygon, :route, :isochrone, :boundary]
  @geo_set_types [:point_set, :line_set, :polygon_set, :geo_set]
  @element_types [:geo_element]
  @chainable_types @geo_set_types ++ @element_types ++ [:route, :isochrone, :boundary]

  @spatial_methods [
    :within,
    :not_within,
    :around,
    :bbox,
    :h3,
    :intersects,
    :not_intersects,
    :contains,
    :not_contains,
    :crosses,
    :touches,
    :member_of,
    :has_member
  ]
  @transform_methods [:buffer, :simplify, :centroid]
  @computed_methods [:elevation, :distance, :area, :length]
  @output_shape_methods [:fields, :include, :precision, :expand]
  @narrowing_methods [:first, :last, :index]
  @ordering_methods [:sort, :limit, :offset]
  @aggregation_methods [:sum, :min, :max, :avg]
  @output_mode_methods [:count, :ids, :tags, :skel, :geom] ++ @aggregation_methods

  @display_names %{
    point: "Point",
    linestring: "LineString",
    polygon: "Polygon",
    point_set: "PointSet",
    line_set: "LineSet",
    polygon_set: "PolygonSet",
    geo_set: "GeoSet",
    geo_element: "GeoElement",
    value_set: "ValueSet",
    route: "Route",
    isochrone: "Isochrone",
    boundary: "Boundary",
    matrix: "Matrix",
    elevation: "Elevation",
    grouped_set: "GroupedSet",
    scalar: "Scalar"
  }

  @doc "Is this type usable as a geometry argument to spatial methods?"
  @spec geometric?(pql_type()) :: boolean()
  def geometric?(type), do: type in @geometry_types

  @doc "Is this type a feature collection?"
  @spec geo_set?(pql_type()) :: boolean()
  def geo_set?(type), do: type in @geo_set_types

  @doc "Is this a strict subtype of GeoSet (PointSet, LineSet, PolygonSet)?"
  @spec subtype_of_geo_set?(pql_type()) :: boolean()
  def subtype_of_geo_set?(type), do: type in [:point_set, :line_set, :polygon_set]

  @doc "Is this type a single element (narrowed from a set)?"
  @spec geo_element?(pql_type()) :: boolean()
  def geo_element?(type), do: type in @element_types

  @doc "Is this method a narrowing method (set→element)?"
  @spec narrowing?(atom()) :: boolean()
  def narrowing?(method), do: method in @narrowing_methods

  @doc "Is this type chainable (can have methods called on it)?"
  @spec chainable?(pql_type()) :: boolean()
  def chainable?(type), do: type in @chainable_types

  @doc "Human-readable display name for a type."
  @spec display_name(pql_type()) :: String.t()
  def display_name(type), do: Map.get(@display_names, type, to_string(type))

  @doc "Is this method an output mode (terminal, max one per chain)?"
  @spec output_mode?(atom()) :: boolean()
  def output_mode?(method), do: method in @output_mode_methods

  @type method_group :: :freely_orderable | :late_chain | :terminal

  @doc "What ordering group does this method belong to?"
  @spec method_group(atom()) :: method_group()
  def method_group(method) do
    cond do
      method == :group_by -> :late_chain
      method in @narrowing_methods -> :late_chain
      method in @ordering_methods -> :late_chain
      method in @output_mode_methods -> :terminal
      true -> :freely_orderable
    end
  end

  @doc "Human-readable category name for a method."
  @method_categories for {cat, methods} <- [
                           {"spatial", @spatial_methods},
                           {"filter", [:filter, :filter_expr]},
                           {"transform", @transform_methods},
                           {"computed", @computed_methods},
                           {"output shape", @output_shape_methods},
                           {"narrowing", @narrowing_methods},
                           {"ordering", @ordering_methods},
                           {"grouping", [:group_by]},
                           {"output mode", @output_mode_methods}
                         ],
                         m <- methods,
                         into: %{},
                         do: {m, cat}

  @spec method_category(atom()) :: String.t()
  def method_category(method), do: Map.get(@method_categories, method, "unknown")

  @doc "What type does a method produce given an input type?"
  @spec method_output_type(atom(), pql_type()) :: {:ok, pql_type()} | {:error, String.t()}
  def method_output_type(:centroid, t) when t in @chainable_types, do: {:ok, :point_set}
  def method_output_type(:buffer, t) when t in @chainable_types, do: {:ok, :polygon_set}
  def method_output_type(:count, t) when t in @chainable_types, do: {:ok, :scalar}

  # Aggregation methods on chainable types → scalar
  def method_output_type(m, t) when m in [:sum, :min, :max, :avg] and t in @chainable_types,
    do: {:ok, :scalar}

  # group_by on chainable types → grouped_set
  def method_output_type(:group_by, t) when t in @chainable_types, do: {:ok, :grouped_set}

  # Aggregation terminals on grouped_set → scalar
  def method_output_type(:count, :grouped_set), do: {:ok, :scalar}

  def method_output_type(m, :grouped_set) when m in [:sum, :min, :max, :avg],
    do: {:ok, :scalar}

  # Non-aggregation methods on grouped_set → error
  def method_output_type(m, :grouped_set) do
    {:error,
     "`.#{m}()` cannot be applied to GroupedSet — only aggregation methods (`.count()`, `.sum()`, `.min()`, `.max()`, `.avg()`) are valid after `.group_by()`"}
  end

  # Narrowing: geo_set → geo_element
  def method_output_type(m, t) when m in [:first, :last, :index] and t in @geo_set_types,
    do: {:ok, :geo_element}

  def method_output_type(m, :geo_element) when m in [:first, :last, :index],
    do: {:error, "`.#{m}()` cannot be applied to GeoElement — it is already a single element"}

  # member_of/has_member return same type (chainable)
  def method_output_type(:member_of, t) when t in @chainable_types, do: {:ok, t}

  def method_output_type(:has_member, :geo_element),
    do:
      {:error,
       "`.has_member()` cannot be applied to a single element — nodes cannot contain members"}

  def method_output_type(:has_member, t) when t in @geo_set_types, do: {:ok, t}

  @all_methods @spatial_methods ++
                 [:filter, :filter_expr] ++
                 @transform_methods ++
                 @computed_methods ++
                 @output_shape_methods ++
                 @narrowing_methods ++
                 @ordering_methods ++
                 [:group_by] ++
                 @output_mode_methods

  def method_output_type(m, t) when t in @chainable_types do
    if m in @all_methods do
      {:ok, t}
    else
      {:error, "unknown method `.#{m}()`"}
    end
  end

  def method_output_type(m, t) when t in [:matrix, :elevation, :scalar] do
    {:error,
     "`.#{m}()` cannot be applied to #{display_name(t)} — #{display_name(t)} is a terminal type that does not support chaining"}
  end

  def method_output_type(m, t),
    do: {:error, "`.#{m}()` cannot be applied to #{display_name(t)}"}

  @doc "What types are valid as geometry arguments for this spatial method?"
  @spec valid_spatial_arg_types(atom()) :: [pql_type()]
  @containment_types [:boundary, :isochrone, :polygon, :polygon_set]
  def valid_spatial_arg_types(m) when m in [:within, :not_within], do: @containment_types
  def valid_spatial_arg_types(:crosses), do: [:linestring, :route, :line_set]
  def valid_spatial_arg_types(_), do: @geometry_types ++ @geo_set_types

  @doc "Compute the union type of two types."
  @spec union_type(pql_type(), pql_type()) :: pql_type()
  def union_type(same, same), do: same
  def union_type(_, _), do: :geo_set

  @doc "Compute the intersection type of two types."
  @spec intersection_type(pql_type(), pql_type()) :: pql_type()
  def intersection_type(same, same), do: same
  def intersection_type(_, _), do: :geo_set
end
