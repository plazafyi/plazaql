defmodule PlazaQL.SQL.Branch do
  @moduledoc false
  # Internal: one branch of a query — an element type's table or a custom
  # source — with the schema its SQL is written against.

  alias PlazaQL.Plan
  alias PlazaQL.Schema
  alias PlazaQL.Schema.Source

  @type name :: Plan.element_type() | String.t()

  @type t :: %__MODULE__{
          name: name(),
          table: String.t(),
          label: String.t(),
          type_value: String.t(),
          schema: Schema.t(),
          keys: [String.t()],
          full_columns: [String.t()],
          rank: integer(),
          element?: boolean(),
          partitioned?: boolean(),
          typed_values?: boolean(),
          sparse_tile_id?: boolean()
        }

  defstruct [
    :name,
    :table,
    :label,
    :type_value,
    :schema,
    :keys,
    :full_columns,
    rank: 0,
    element?: true,
    partitioned?: false,
    typed_values?: false,
    sparse_tile_id?: false
  ]

  @doc "Every branch of `plan`: its element types, then its sources, ranked in that order."
  @spec all(Plan.t(), Schema.t()) :: [t()]
  def all(%Plan{} = plan, %Schema{} = schema) do
    (plan.element_types ++ (plan.sources || []))
    |> Enum.with_index()
    |> Enum.map(fn {name, rank} -> resolve(name, schema, rank) end)
  end

  @doc """
  The branch `name` (an element type or a source name). Without an explicit
  rank, an element type ranks at its index in `plan.element_types`.
  """
  @spec resolve(name() | t(), Schema.t(), integer()) :: t()
  def resolve(%__MODULE__{} = branch, _schema, _rank), do: branch

  def resolve(type, %Schema{} = schema, rank) when type in [:node, :way, :relation, :boundary] do
    table_type = if type == :boundary, do: :relation, else: type

    %__MODULE__{
      name: type,
      table: Map.fetch!(schema.tables, table_type),
      label: Atom.to_string(type),
      # `boundary` rows are relations
      type_value: Atom.to_string(table_type),
      schema: schema,
      keys: [schema.columns.id],
      full_columns: Map.get(schema.full_columns, table_type, []),
      rank: rank,
      partitioned?: Schema.partitioned?(schema, table_type)
    }
  end

  def resolve(name, %Schema{} = schema, rank) when is_binary(name) do
    case Map.fetch(schema.sources, name) do
      {:ok, %Source{} = source} -> from_source(source, schema, rank)
      :error -> raise ArgumentError, "unknown source #{inspect(name)}: not in schema.sources"
    end
  end

  def resolve(other, _schema, _rank),
    do: raise(ArgumentError, "unknown element type or source #{inspect(other)}")

  @doc "The rank `name` has among `plan`'s branches (0 when it isn't one)."
  @spec rank(Plan.t(), name()) :: non_neg_integer()
  def rank(%Plan{} = plan, name) do
    case Enum.find_index(plan.element_types ++ (plan.sources || []), &(&1 == name)) do
      nil -> 0
      index -> index
    end
  end

  defp from_source(%Source{} = source, %Schema{} = schema, rank) do
    columns = Map.merge(schema.columns, source.columns)
    branch_schema = %{schema | columns: columns}

    %__MODULE__{
      name: source.name,
      table: source.table,
      label: source.type,
      type_value: source.type,
      schema: branch_schema,
      keys: source.keys || [columns.id],
      full_columns: source.full_columns,
      rank: rank,
      element?: false,
      partitioned?: false,
      typed_values?: source.typed_values,
      sparse_tile_id?: source.sparse_tile_id
    }
  end

  @doc """
  Bind `type()` in the plan's expressions to the branch's type: it is
  constant over one table, so `type() == "node"` compares two literals.
  """
  @spec bind_type(Plan.t(), t()) :: Plan.t()
  def bind_type(%Plan{} = plan, %__MODULE__{type_value: value}) do
    %{
      plan
      | filter_exprs: bind(plan.filter_exprs, value),
        sort_expr: bind(plan.sort_expr, value),
        aggregate_expr: bind(plan.aggregate_expr, value),
        group_by: bind(plan.group_by, value),
        computed_columns: bind(plan.computed_columns, value)
    }
  end

  defp bind({:prop_access, :type, pos}, value), do: {:string, value, pos}

  defp bind(tuple, value) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&bind(&1, value))
    |> List.to_tuple()
  end

  defp bind(list, value) when is_list(list), do: Enum.map(list, &bind(&1, value))
  defp bind(other, _value), do: other
end
