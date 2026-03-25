defmodule PlazaQL.Parser do
  @moduledoc """
  Parser for PlazaQL queries.

  Uses tree-sitter to parse PQL source into a CST, then transforms it into
  an AST with source positions on every node.

  ## Public API

      PlazaQL.Parser.parse("search(node, amenity: \\"cafe\\").limit(10);")

  Returns `{:ok, [ast_node]}` or `{:error, [%PlazaQL.Error{}]}`.
  """

  alias PlazaQL.Error

  @spec parse(String.t()) :: {:ok, [term()]} | {:error, [Error.t()]}
  defdelegate parse(source), to: PlazaQL.TreeSitter
end
