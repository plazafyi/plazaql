defmodule PlazaQL.Query do
  @moduledoc """
  Result of compiling a PlazaQL plan to SQL.

  Contains a parameterized SQL string and its parameter values,
  ready to be executed against any PostGIS database.

  ## Example

      {:ok, %PlazaQL.Query{sql: sql, params: params}} = PlazaQL.to_sql(plan)
      {:ok, result} = Postgrex.query(conn, sql, params)
  """

  @type t :: %__MODULE__{
          sql: String.t(),
          params: [term()],
          plan: PlazaQL.Plan.t() | nil,
          metadata: map()
        }

  defstruct [:sql, :params, :plan, metadata: %{}]
end
