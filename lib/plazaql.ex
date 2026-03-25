defmodule PlazaQL do
  @moduledoc """
  PlazaQL query language — parse, check, and format.

  ## Pipeline

      source string
        → Parser.parse/1      (AST)
        → TypeChecker.check/1 (typed AST)

  Each stage can be called independently or via the convenience functions here.
  """

  alias PlazaQL.Error
  alias PlazaQL.Formatter
  alias PlazaQL.Parser
  alias PlazaQL.TypeChecker

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
  Parse and format PlazaQL source.

  Returns `{:ok, formatted_string}` or `{:error, [Error.t()]}`.
  """
  @spec format(String.t()) :: {:ok, String.t()} | {:error, [Error.t()]}
  def format(source) do
    with {:ok, ast} <- Parser.parse(source), do: {:ok, Formatter.format(ast)}
  end
end
