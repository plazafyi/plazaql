defmodule PlazaQL.Schema do
  @moduledoc """
  Describes the target database schema for SQL generation.

  Configures table names, column names, SRID, and optional extensions.
  Defaults match the standard OpenStreetMap schema used by most importers.
  """

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
            partition_tile_id: String.t() | nil
          },
          srid: pos_integer(),
          limits: %{max_osm_ids: pos_integer()},
          extensions: %{h3: boolean(), partition_pruning: boolean()},
          elevation_table: String.t() | nil
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
              partition_tile_id: nil
            },
            srid: 4326,
            limits: %{max_osm_ids: 10_000},
            extensions: %{h3: false, partition_pruning: false},
            elevation_table: nil

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
      |> Enum.reduce(defaults, fn
        {:tables, overrides}, acc when is_list(overrides) ->
          %{acc | tables: Map.merge(acc.tables, Map.new(overrides))}

        {:columns, overrides}, acc when is_list(overrides) ->
          %{acc | columns: Map.merge(acc.columns, Map.new(overrides))}

        {:limits, overrides}, acc when is_list(overrides) ->
          %{acc | limits: Map.merge(acc.limits, Map.new(overrides))}

        {:extensions, overrides}, acc when is_list(overrides) ->
          %{acc | extensions: Map.merge(acc.extensions, Map.new(overrides))}

        {key, value}, acc when key in [:srid, :elevation_table] ->
          Map.put(acc, key, value)

        {key, _value}, _acc ->
          raise ArgumentError, "unknown schema option: #{inspect(key)}"
      end)

    validate!(schema)
    schema
  end

  @doc "Default schema for standard OSM imports."
  @spec default() :: t()
  def default(), do: new()

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
      if schema.elevation_table,
        do: table_values ++ column_values ++ [schema.elevation_table],
        else: table_values ++ column_values

    Enum.each(identifier_values, fn name ->
      unless Regex.match?(@identifier_re, name) do
        raise ArgumentError,
              "invalid identifier #{inspect(name)}: must match ~r/^[a-z_][a-z0-9_]*$/"
      end
    end)
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
