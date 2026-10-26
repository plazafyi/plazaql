defmodule PlazaQL.Schema.Source do
  @moduledoc """
  A custom source: a table of features queried like an element type.

  A plan lists the sources it reads in `PlazaQL.Plan.sources`; each one is a
  branch of the query after the element types (see `PlazaQL.SQL.branches/2`).
  A source's rows have no OSM identity, so `osm_ids`, metadata filters and
  partition filters don't apply to it.

  ## Options

    * `:table` (required) — the table name.
    * `:type` — the `__type__` label of its rows, and what `type()` evaluates
      to in expressions (default: the source's name).
    * `:columns` — overrides of the schema's column names for this table
      (`id`, `geometry`, `tags`, `filter_tags`, `tile_id`).
    * `:keys` — the columns that identify a row, in order (default: the id
      column). Rows are ordered by them after the sort, keyset pagination
      compares them, and `:ids`, `:skel` and `:tags` output select them.
    * `:full_columns` — extra columns `:full` output selects.
    * `:typed_values` — the filter column holds typed JSON values: an
      equality filter `key: "5"` also matches the number `5`, `"true"` the
      boolean (only forms that print back to the filter string).
    * `:sparse_tile_id` — rows whose geometry fits no single H3 cell have a
      NULL tile id; H3 filters keep them as candidates and decide by geometry.

  ## Example

      PlazaQL.Schema.new(
        sources: [
          places: [
            table: "my_places",
            type: "place",
            columns: [id: "id", filter_tags: "properties"],
            keys: ["id", "collection_id"]
          ]
        ]
      )
  """

  alias PlazaQL.Schema

  @type t :: %__MODULE__{
          name: String.t(),
          table: String.t(),
          type: String.t(),
          columns: %{optional(atom()) => String.t() | nil},
          keys: [String.t()] | nil,
          full_columns: [String.t()],
          typed_values: boolean(),
          sparse_tile_id: boolean()
        }

  @enforce_keys [:name, :table, :type]
  defstruct [
    :name,
    :table,
    :type,
    columns: %{},
    keys: nil,
    full_columns: [],
    typed_values: false,
    sparse_tile_id: false
  ]

  @column_keys [:id, :geometry, :tags, :filter_tags, :tile_id]
  @options [:table, :type, :columns, :keys, :full_columns, :typed_values, :sparse_tile_id]

  @doc "Build a source named `name` from keyword options (see the module doc)."
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts) when is_binary(name) and is_list(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown source option(s) #{inspect(unknown)} for #{name}"
    end

    table = Keyword.get(opts, :table) || raise ArgumentError, "source #{name} needs a :table"
    columns = Map.new(Keyword.get(opts, :columns, []))

    case Map.keys(columns) -- @column_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown source column(s) #{inspect(unknown)} for #{name}"
    end

    %__MODULE__{
      name: Schema.validate_identifier!(name),
      table: Schema.validate_identifier!(table),
      type: Schema.validate_identifier!(Keyword.get(opts, :type, name)),
      columns:
        Map.new(columns, fn {key, col} -> {key, col && Schema.validate_identifier!(col)} end),
      keys: validate_list(Keyword.get(opts, :keys)),
      full_columns: validate_list(Keyword.get(opts, :full_columns, [])),
      typed_values: Keyword.get(opts, :typed_values, false) == true,
      sparse_tile_id: Keyword.get(opts, :sparse_tile_id, false) == true
    }
  end

  defp validate_list(nil), do: nil
  defp validate_list(cols) when is_list(cols), do: Enum.map(cols, &Schema.validate_identifier!/1)
end
