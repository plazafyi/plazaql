defmodule PlazaQL do
  @moduledoc """
  PlazaQL query language — parse, check, compile, and generate SQL.

  ## Pipeline

      source string
        → Parser.parse/1      (AST)
        → TypeChecker.check/1 (validated AST)
        → Compiler.compile/2  (Plan IR)
        → SQL.to_sql/2        (one parameterized SQL statement)
          or SQL.branches/2   (one statement per element type or source)

  Each stage can be called independently or via the convenience functions here.

  For the common case of source → SQL, use `query/2`:

      {:ok, %PlazaQL.Query{sql: sql, params: params}} =
        PlazaQL.query(~s|search(node, amenity: "cafe").bbox(40.0, -74.0, 41.0, -73.0);|)

      {:ok, result} = Postgrex.query(conn, sql, params)

  Computations (`route(...)`, `isochrone(...)`, ...) compile to plans but not
  to SQL: `to_sql/2` returns `{:error, %PlazaQL.NotCompilable{}}` for them,
  and the caller runs them. See the "Using the Elixir library" section of the
  README and `docs/compiler.md`.
  """

  alias PlazaQL.Compiler
  alias PlazaQL.Error
  alias PlazaQL.Formatter
  alias PlazaQL.NotCompilable
  alias PlazaQL.Parser
  alias PlazaQL.Plan
  alias PlazaQL.Query
  alias PlazaQL.Schema
  alias PlazaQL.TypeChecker

  @doc """
  Parse, type-check, and compile PlazaQL source into Plan IR.

  Returns `{:ok, compile_result}` or `{:error, [Error.t()]}`.
  """
  @spec compile(String.t(), keyword()) :: {:ok, Compiler.compile_result()} | {:error, [Error.t()]}
  def compile(source, opts \\ []) do
    with {:ok, ast} <- Parser.parse(source),
         {:ok, checked} <- TypeChecker.check(ast) do
      Compiler.compile(checked, opts)
    end
  end

  @doc """
  Parse PlazaQL source into an AST.

  Returns `{:ok, [ast_node]}` or `{:error, [Error.t()]}`.
  """
  @spec parse(String.t()) :: {:ok, [term()]} | {:error, [Error.t()]}
  def parse(source), do: Parser.parse(source)

  @doc """
  Parse and type-check PlazaQL source.

  Returns `{:ok, [typed_ast]}` or `{:error, [Error.t()]}`.
  """
  @spec check(String.t()) :: {:ok, [term()]} | {:error, [Error.t()]}
  def check(source) do
    with {:ok, ast} <- Parser.parse(source), do: TypeChecker.check(ast)
  end

  @doc """
  Compile a Plan to parameterized SQL.

  Returns `{:ok, PlazaQL.Query.t()}` or `{:error, PlazaQL.NotCompilable.t()}`.
  """
  @spec to_sql(Plan.t(), Schema.t()) :: {:ok, Query.t()} | {:error, NotCompilable.t()}
  def to_sql(plan, schema \\ Schema.new()) do
    PlazaQL.SQL.to_sql(plan, schema)
  end

  @doc """
  Compile a Plan to one query per branch (element type or custom source),
  for callers that run branches separately and merge their rows. See
  `PlazaQL.SQL.branches/2`.
  """
  @spec branches(Plan.t(), Schema.t()) ::
          {:ok, [{Plan.element_type() | String.t(), Query.t()}]} | {:error, NotCompilable.t()}
  def branches(plan, schema \\ Schema.new()), do: PlazaQL.SQL.branches(plan, schema)

  @doc """
  Parse, compile, and generate SQL from PlazaQL source.

  Returns `{:ok, Query.t()}` for single-plan queries.
  """
  @spec query(String.t(), keyword()) :: {:ok, Query.t()} | {:error, term()}
  def query(source, opts \\ []) do
    schema = Keyword.get(opts, :schema, Schema.new())

    with {:ok, ast} <- Parser.parse(source),
         {:ok, checked} <- TypeChecker.check(ast),
         {:ok, %{plans: [plan | _]}} <- Compiler.compile(checked, opts) do
      PlazaQL.SQL.to_sql(plan, schema)
    end
  end

  @doc """
  Parse and format PlazaQL source.

  Returns `{:ok, formatted_string}` or `{:error, [Error.t()]}`.
  """
  @spec format(String.t()) :: {:ok, String.t()} | {:error, [Error.t()]}
  def format(source) do
    with {:ok, ast} <- Parser.parse(source), do: {:ok, Formatter.format(ast)}
  end
end
