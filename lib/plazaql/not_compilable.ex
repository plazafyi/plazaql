defmodule PlazaQL.NotCompilable do
  @moduledoc """
  Raised when a plan cannot be compiled to SQL.

  This occurs for computation plans (route, isochrone, geocode, etc.)
  which require a service backend rather than direct SQL execution.
  The caller is responsible for implementing computation execution.
  """

  @type t :: %__MODULE__{
          reason: atom(),
          plan: PlazaQL.Plan.t() | nil,
          message: String.t()
        }

  defexception [:reason, :plan, :message]

  @impl true
  def message(%__MODULE__{message: msg}) when is_binary(msg) and msg != "", do: msg
  def message(%__MODULE__{reason: reason}), do: "plan is not compilable to SQL: #{reason}"
end
