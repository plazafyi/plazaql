defmodule PlazaQL.Schema do
  @moduledoc """
  Describes the target database schema for SQL generation.

  Configures table names, column names, SRID, and optional extensions.
  Defaults match the standard OpenStreetMap schema used by most importers.

  Besides the node, way and relation tables, a schema can name custom
  **sources** (`PlazaQL.Schema.Source`): other tables of features with a
  geometry and a jsonb column of properties, queried by listing their names
  in `PlazaQL.Plan.sources`.

  ## Options beyond table and column names

    * `columns: [filter_tags: "properties"]` — the jsonb column tag filters
      and `t["key"]` read (defaults to the `tags` column, which output reads).
    * `full_columns: [node: ["version", ...]]` — extra columns `:full` output
      selects from an element type's table, besides id, tags and geometry.
    * `partitioned: [:node, :way]` — the element types whose tables carry the
      `partition_tile_id` column (default: every type, when the column is set).
    * `limits: [max_h3_tiles: 20]` — a caller-resolved H3 tile prefilter with
      more cells than this is skipped (the spatial filter alone decides).
    * `elevation_resolution_column: "resolution"` — with several rasters
      covering a point, `elevation()` reads the finest one that has a value.
  """

  alias PlazaQL.Schema.Source

  @type element_type :: :node | :way | :relation

  @type t :: %__MODULE__{
          tables: %{
            node: String.t(),
            way: String.t(),
            relation: String.t(),
            admin_boundaries: String.t() | nil
          },
          columns: %{
            id: String.t(),
            geometry: String.t(),
            tags: String.t(),
            tile_id: String.t() | nil,
            partition_tile_id: String.t() | nil,
            filter_tags: String.t() | nil
          },
          full_columns: %{optional(element_type()) => [String.t()]},
          partitioned: [element_type()] | nil,
          sources: %{optional(String.t()) => Source.t()},
          srid: pos_integer(),
          limits: %{max_osm_ids: pos_integer(), max_h3_tiles: pos_integer()},
          extensions: %{h3: boolean(), partition_pruning: boolean()},
          elevation_table: String.t() | nil,
          elevation_resolution_column: String.t() | nil
        }

  defstruct tables: %{
              node: "osm_nodes",
              way: "osm_ways",
              relation: "osm_relations",
              admin_boundaries: nil
            },
            columns: %{
              id: "osm_id",
              geometry: "geom",
              tags: "tags",
              tile_id: nil,
              partition_tile_id: nil,
              filter_tags: nil
            },
            full_columns: %{},
            partitioned: nil,
            sources: %{},
            srid: 4326,
            limits: %{max_osm_ids: 10_000, max_h3_tiles: 20},
            extensions: %{h3: false, partition_pruning: false},
            elevation_table: nil,
            elevation_resolution_column: nil

  @identifier_re ~r/^[a-z_][a-z0-9_]*$/

  # Flat keyword shortcuts → {map_key, field_key}
  @flat_shortcuts %{
    node_table: {:tables, :node},
    way_table: {:tables, :way},
    relation_table: {:tables, :relation},
    admin_boundaries_table: {:tables, :admin_boundaries},
    id_column: {:columns, :id},
    geometry_column: {:columns, :geometry},
    tags_column: {:columns, :tags},
    tile_id_column: {:columns, :tile_id},
    partition_tile_id_column: {:columns, :partition_tile_id}
  }

  @doc "Create a schema from keyword opts merged onto defaults."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    defaults = %__MODULE__{}

    schema =
      opts
      |> expand_flat_shortcuts()
      |> Enum.reduce(defaults, &put_option/2)

    validate!(schema)
    schema
  end

  defp put_option({:tables, overrides}, acc) when is_list(overrides),
    do: %{acc | tables: Map.merge(acc.tables, Map.new(overrides))}

  defp put_option({:columns, overrides}, acc) when is_list(overrides),
    do: %{acc | columns: Map.merge(acc.columns, Map.new(overrides))}

  defp put_option({:limits, overrides}, acc) when is_list(overrides),
    do: %{acc | limits: Map.merge(acc.limits, Map.new(overrides))}

  defp put_option({:extensions, overrides}, acc) when is_list(overrides),
    do: %{acc | extensions: Map.merge(acc.extensions, Map.new(overrides))}

  defp put_option({:full_columns, columns}, acc) when is_list(columns) or is_map(columns),
    do: %{acc | full_columns: Map.merge(acc.full_columns, Map.new(columns))}

  defp put_option({:sources, sources}, acc) when is_list(sources) or is_map(sources),
    do: %{acc | sources: Map.merge(acc.sources, new_sources(sources))}

  defp put_option({key, value}, acc)
       when key in [:srid, :elevation_table, :elevation_resolution_column, :partitioned],
       do: Map.put(acc, key, value)

  defp put_option({key, _value}, _acc),
    do: raise(ArgumentError, "unknown schema option: #{inspect(key)}")

  @doc "Default schema for standard OSM imports."
  @spec default() :: t()
  def default(), do: new()

  @doc """
  Whether an element type's table carries the partition column, so a
  caller-resolved partition filter (and `:keys` output's partition key)
  applies to it.
  """
  @spec partitioned?(t(), element_type()) :: boolean()
  def partitioned?(%__MODULE__{columns: %{partition_tile_id: nil}}, _type), do: false
  def partitioned?(%__MODULE__{partitioned: nil}, _type), do: true
  def partitioned?(%__MODULE__{partitioned: types}, type), do: type in types

  @doc "The jsonb column tag filters and `t[...]` read."
  @spec filter_tags_column(t()) :: String.t()
  def filter_tags_column(%__MODULE__{columns: columns}), do: columns.filter_tags || columns.tags

  defp new_sources(sources) do
    Map.new(sources, fn
      {name, %Source{} = source} -> {to_string(name), source}
      {name, opts} when is_list(opts) -> {to_string(name), Source.new(to_string(name), opts)}
    end)
  end

  defp expand_flat_shortcuts(opts) do
    {flat, rest} = Keyword.split(opts, Map.keys(@flat_shortcuts))

    nested =
      flat
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        {map_key, field_key} = Map.fetch!(@flat_shortcuts, key)

        Map.update(acc, map_key, [{field_key, value}], &[{field_key, value} | &1])
      end)
      |> Enum.to_list()

    # Merge nested from flat shortcuts with any explicit nested opts.
    # Explicit nested opts take precedence.
    Keyword.merge(nested, rest, fn _key, flat_val, explicit_val when is_list(explicit_val) ->
      Keyword.merge(flat_val, explicit_val)
    end)
  end

  defp validate!(%__MODULE__{} = schema) do
    validate_identifiers!(schema)
    validate_extension_consistency!(schema)
  end

  defp validate_identifiers!(%__MODULE__{} = schema) do
    table_values =
      schema.tables
      |> Map.values()
      |> Enum.reject(&is_nil/1)

    column_values =
      schema.columns
      |> Map.values()
      |> Enum.reject(&is_nil/1)

    identifier_values =
      table_values ++
        column_values ++
        Enum.flat_map(schema.full_columns, fn {_type, cols} -> cols end) ++
        Enum.reject([schema.elevation_table, schema.elevation_resolution_column], &is_nil/1)

    Enum.each(identifier_values, &validate_identifier!/1)
  end

  @doc false
  # Table and column names are interpolated into SQL, so they must be plain
  # lowercase identifiers.
  @spec validate_identifier!(String.t()) :: String.t()
  def validate_identifier!(name) when is_binary(name) do
    if Regex.match?(@identifier_re, name) do
      name
    else
      raise ArgumentError, "invalid identifier #{inspect(name)}: must match ~r/^[a-z_][a-z0-9_]*$/"
    end
  end

  defp validate_extension_consistency!(%__MODULE__{} = schema) do
    if schema.extensions.h3 && is_nil(schema.columns.tile_id) do
      raise ArgumentError,
            "columns.tile_id must be set when extensions.h3 is true"
    end

    if schema.extensions.partition_pruning && is_nil(schema.columns.partition_tile_id) do
      raise ArgumentError,
            "columns.partition_tile_id must be set when extensions.partition_pruning is true"
    end
  end
end
