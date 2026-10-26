defmodule PlazaQL.Plan do
  @moduledoc """
  Unified query IR for PlazaQL.

  Represents a fully resolved query that can be compiled to SQL.
  Built by `PlazaQL.Compiler` from PlazaQL AST.
  """

  alias PlazaQL.Plan.OutputOptions

  @type element_type :: :node | :way | :relation | :boundary

  @type tag_filter ::
          {:eq, String.t(), String.t()}
          | {:neq, String.t(), String.t()}
          | {:exists, String.t()}
          | {:not_exists, String.t()}
          | {:regex, String.t(), String.t()}
          | {:regex_i, String.t(), String.t()}
          | {:not_regex, String.t(), String.t()}
          | {:is_in, String.t()}
          | {:bracket_eq, String.t(), String.t(), String.t()}
          | {:any_of, String.t(), [String.t()]}
          | {:key_value_regex, String.t(), String.t()}
          | {:key_regex_exists, String.t()}
          | :impossible

  @type predicate ::
          :within
          | :intersects
          | :contains
          | :crosses
          | :touches
          | :not_within
          | :not_intersects
          | :not_contains

  @type spatial_filter ::
          {:bbox, float(), float(), float(), float()}
          | {:around, float(), float(), float()}
          | {:polygon, [{float(), float()}]}
          | {:h3, String.t()}
          | {:boundary_set, String.t()}
          | {:around_set, String.t(), number()}
          | {:around_set_resolved, [String.t()], number()}
          | {:predicate, predicate(), geometry()}

  @type output_mode ::
          :full | :ids | :skel | :count | :tags | :sum | :min | :max | :avg | :tile

  @type kind :: :query | :computation

  @type computation_type ::
          :route
          | :isochrone
          | :matrix
          | :geocode
          | :reverse_geocode
          | :map_match
          | :optimize
          | :ev_route
          | :elevation_lookup
          | :elevation_profile
          | :place_lookup
          | :search
          | :autocomplete
          | :nearest
          | :centroid
          | :expansion

  @type computation :: {computation_type(), map()}

  @type metadata_filter ::
          {:newer, DateTime.t()}
          | {:version, pos_integer()}
          | {:changeset, pos_integer()}

  @type eval_filter ::
          {:gt, String.t(), number()}
          | {:lt, String.t(), number()}
          | {:gte, String.t(), number()}
          | {:lte, String.t(), number()}

  @type filter_expr :: term()

  @typedoc """
  Geometry argument of a spatial predicate. Coordinates are `{lng, lat}`.

  `{:set_ref, name}` references a named set resolved by the executor at run
  time: `"name"` for `$name`, `"$$.name"` for `$$.name`.
  """
  @type geometry ::
          {:point, float(), float()}
          | {:polygon, [[{float(), float()}]]}
          | {:linestring, [{float(), float()}]}
          | {:set_ref, String.t()}

  @typedoc """
  Reference geometry for `overlap_fraction`: a closed `{lng, lat}` polygon ring
  or a named set ref (see `PlazaQL.GeometryRef`).
  """
  @type geometry_ref :: PlazaQL.GeometryRef.t()

  @typedoc """
  Computed column: `{alias, expr}`. Built-ins are `{:elevation_m, ...}`,
  `{:length_m, ...}`, `{:area_m2, ...}`, `{:distance_m, {:geom_func, :distance, {lat, lng}, nil}}`,
  and `{:overlap_fraction, {:geom_func, :overlap_fraction, geometry_ref(), nil}}`.
  """
  @type computed_column :: {atom(), term()}

  @type recurse_direction :: :down | :up | :down_full | :up_full

  @type member_filter ::
          {:member_of, element_type() | nil, element_type() | nil, String.t() | t(),
           String.t() | nil}
          | {:has_member, element_type() | nil, element_type() | nil, String.t() | t(),
             String.t() | nil}

  @type narrow :: :first | :last | {:index, number()}

  @typedoc """
  `.tile(z, x, y, layers: [...])`: render the search's elements as one
  Mapbox Vector Tile at slippy-map coordinates z/x/y. `layers` is `nil` when
  not given (the server picks its default layers).
  """
  @type tile :: %{
          z: non_neg_integer(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          layers: [String.t()] | nil
        }

  @type t :: %__MODULE__{
          element_types: [element_type()],
          tag_filters: [tag_filter()],
          spatial_filter: spatial_filter() | nil,
          scope_geometry: spatial_filter() | nil,
          osm_ids: [integer()] | nil,
          metadata_filters: [metadata_filter()],
          filter_exprs: [filter_expr()],
          output_mode: output_mode(),
          output_options: OutputOptions.t() | nil,
          computed_columns: [computed_column()],
          distinct: boolean(),
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          sort_expr: {term(), :asc | :desc} | nil,
          aggregate_expr: term() | nil,
          group_by: term() | nil,
          set_ops: [{atom(), t() | [t()]}],
          sources: [String.t()] | nil,
          kind: kind(),
          computation: computation() | nil,
          caller_context: map(),
          custom_clauses: [{String.t(), [term()]}],
          recurse: recurse_direction() | nil,
          narrow: narrow() | nil,
          member_filter: member_filter() | nil,
          tile: tile() | nil
        }

  defstruct element_types: [:node, :way, :relation],
            tag_filters: [],
            spatial_filter: nil,
            scope_geometry: nil,
            osm_ids: nil,
            metadata_filters: [],
            filter_exprs: [],
            output_mode: :full,
            output_options: nil,
            computed_columns: [],
            distinct: false,
            limit: nil,
            offset: nil,
            sort_expr: nil,
            aggregate_expr: nil,
            group_by: nil,
            set_ops: [],
            sources: nil,
            kind: :query,
            computation: nil,
            caller_context: %{},
            custom_clauses: [],
            recurse: nil,
            narrow: nil,
            member_filter: nil,
            tile: nil
end
