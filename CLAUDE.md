# PlazaQL

PlazaQL is a LINQ-style query language for geospatial data. This repo is the **single source of truth** for the language — grammar, parsers, type system, LSP, syntax highlighting, and examples all live here.

## Quick Commands

```bash
make install      # Full setup (elixir deps, LSP node deps, pre-commit hooks)
make test         # Run ALL tests (Elixir + LSP vitest + tree-sitter corpus)
make compile      # Compile with warnings-as-errors
make format       # Auto-format (mix format + biome)
make precommit    # Full lint/format/typecheck via prek
```

Always use `make` targets. Never run `mix` or `bun` directly.

## Architecture

This repo contains three tightly coupled components sharing a single grammar:

```
grammar.js                    ← tree-sitter grammar (THE canonical syntax definition)
├── src/parser.c              ← generated C parser (tree-sitter generate)
├── queries/highlights.scm    ← syntax highlighting queries
├── test/corpus/              ← tree-sitter corpus tests
│
├── lib/plazaql/              ← Elixir package (mix dep for plaza backend)
│   ├── parser.ex             ← delegates to tree-sitter CLI
│   ├── tree_sitter.ex        ← tree-sitter CLI invocation + CST→AST transform
│   ├── type_checker.ex       ← type validation and method chain ordering
│   ├── types.ex              ← type hierarchy and method catalog
│   ├── formatter.ex          ← AST → formatted PQL source
│   └── error.ex              ← diagnostic error structs
│
├── lsp/                      ← TypeScript LSP (uses tree-sitter WASM)
│   ├── src/parser.ts         ← tree-sitter WASM + CST→AST transform
│   ├── src/types.ts          ← TypeScript AST type definitions
│   ├── src/type-checker.ts   ← type validation
│   ├── src/completions.ts    ← autocomplete/intellisense
│   ├── src/hover.ts          ← hover documentation
│   ├── src/signatures.ts     ← function signature help
│   ├── src/formatter.ts      ← code formatting
│   ├── src/diagnostics.ts    ← error reporting
│   └── src/server.ts         ← LSP server entry point
│
├── tree-sitter-plazaql.wasm  ← compiled WASM parser (shipped in npm package)
├── language-configuration.json
└── examples/*.pql            ← canonical example files
```

## Compiler Architecture

The Elixir package includes a full compiler pipeline that turns PlazaQL source into parameterized SQL:

```
source string
  → Parser.parse/1           (AST tuples)
  → TypeChecker.check/1      (validated AST)
  → Compiler.compile/2       (Plan IR structs)
  → SQL.to_sql/2             (parameterized SQL + params)
```

### Key Modules

| Module | Purpose |
|--------|---------|
| `PlazaQL.Compiler` | AST → `Plan` IR. Walks top-level nodes (outputs, variables, directives) and compiles expressions into Plans. |
| `PlazaQL.Plan` | The intermediate representation. A struct capturing element types, tag filters, spatial filters, set operations, output mode, computed columns, etc. |
| `PlazaQL.Plan.OutputOptions` | Geometry transforms (simplify, buffer, centroid) and result formatting (fields, sort, precision). |
| `PlazaQL.Schema` | Configurable target database schema — table names, column names, SRID, extensions. Defaults to standard OSM. |
| `PlazaQL.SQL` | Top-level SQL generation. Routes plans to UNION ALL (multi-type), aggregation wrappers, or CTE-based set operations. |
| `PlazaQL.SQL.Builder` | Internal. Assembles a complete SELECT for one element type — columns, WHERE, GROUP BY, ORDER BY, LIMIT/OFFSET. |
| `PlazaQL.SQL.Where` | Internal. Builds WHERE clause from spatial filters, tag filters, metadata filters, H3 tiles, and expression filters. |
| `PlazaQL.SQL.Expression` | Internal. Converts expression AST nodes (binary ops, tag access, geometry functions, literals) to SQL fragments. |
| `PlazaQL.Query` | Result struct — holds `sql`, `params`, and optional `plan` reference. |
| `PlazaQL.NotCompilable` | Error for computation plans (route, isochrone, etc.) that can't become SQL and need a service backend. |

### SQL Generation Patterns

- **UNION ALL**: Multi-type queries (e.g. `nwr`) generate one SELECT per element type joined with UNION ALL.
- **CTEs for set ops**: Union (`+`), difference (`-`), intersection (`&`) use `WITH` clauses — `base` CTE plus one CTE per operand.
- **Aggregation wrappers**: Cross-type aggregations (count, sum, avg, etc.) wrap the UNION ALL in an outer SELECT that merges per-type results.
- **Accumulator pattern**: All SQL modules thread `{sql, params, next_idx}` through every build step, ensuring correct `$N` parameter numbering without mutation.

## How It's Consumed

| Consumer | Mechanism | What it uses |
|----------|-----------|-------------|
| **plaza** (backend) | `{:plazaql, path: "../plazaql"}` mix dep | Elixir parser, type-checker, types, formatter, error |
| **plaza** (frontend) | `@plazafyi/plazaql` npm dep | `tree-sitter-plazaql.wasm` + `highlights.scm` via `monaco-tree-sitter` |
| **plaza-docs** | `@plazafyi/plazaql` npm dep | Shiki/ExpressiveCode (PlazaQL renders as plain text pending tree-sitter integration) |
| **VS Code** | LSP server (`plazaql-lsp`) | Full LSP (tree-sitter WASM) |

The compiler pipeline lives in this repo under `lib/plazaql/` — it translates AST into parameterized PostGIS SQL.

## Tree-sitter Grammar

`grammar.js` is the canonical syntax definition. Both Elixir and TypeScript parsers consume it:

- **Elixir**: invokes `tree-sitter parse` CLI, parses XML output, transforms CST→AST tuples
- **TypeScript LSP**: loads `tree-sitter-plazaql.wasm`, transforms CST→AST objects

After editing `grammar.js`:
```bash
tree-sitter generate    # regenerate src/parser.c
tree-sitter test        # run corpus tests
make test               # run ALL tests (Elixir + LSP must also pass)
```

Never edit `src/parser.c` directly — it's generated.

## Elixir AST Format

The parser produces tuples consumed by type-checker, formatter, and plaza's compiler:

```elixir
{:search, :node, [filters], [methods], %{line: 1, col: 1}}
{:boundary, [keyword_args], [methods], %{line: 1, col: 1}}
{:computation, :route, [args], [methods], %{line: 1, col: 1}}
{:variable_assignment, "name", expr, %{line: 1, col: 1}}
{:output_assignment, nil | "name", expr, %{line: 1, col: 1}}
{:method, :within, [args], %{line: 1, col: 1}}
```

Changing AST shape breaks the plaza compiler. Coordinate with the plaza repo.

## TypeScript AST Format

The LSP parser produces typed objects (see `lsp/src/types.ts`):

```typescript
{ kind: "search", elementType: "node", filters: [...], methods: [...], pos: { line: 1, col: 1 } }
```

Every node has `kind` (discriminant) and `pos` (1-based line/col).

## Type System

PlazaQL has 16 types organized into categories:

- **Geometry**: `point`, `linestring`, `polygon`, `route`, `isochrone`, `boundary`
- **Sets**: `point_set`, `line_set`, `polygon_set`, `geo_set`
- **Special**: `geo_element`, `value_set`, `grouped_set`, `matrix`, `elevation`, `scalar`

Methods are ordered by phase — the type-checker enforces this chain ordering.

## PlazaQL Syntax Rules

- **Keyword arguments** accept expressions as values: `point: point(38.9, -77.0)`, `radius: 1000`, `by: :distance`
- **Bare identifiers are NOT valid** as keyword argument values — use atoms (`:distance`), function calls (`distance(point(...))`), or variable refs (`$var`)
- **Tag filters** use `key: "value"` syntax (string/wildcard/regex values only)
- **Set operations**: `+` (union), `-` (difference), `&` (intersection) — only at top-level expressions, NOT inside `.filter()`
- **Filter expressions** inside `.filter()` use arithmetic `+`/`-` and comparison operators

## Testing

Three test suites must all pass:

1. **Tree-sitter corpus** (`tree-sitter test`) — grammar-level syntax tests in `test/corpus/`
2. **Elixir tests** (`mix test`) — parser, type-checker, formatter, error (330 tests)
3. **LSP tests** (`cd lsp && bunx vitest run`) — parser, type-checker, completions, osm-tags (184 tests)

When adding new syntax: add a corpus test, then verify both Elixir and TS CST→AST layers handle the new node type.

## Sibling Repos

This repo must be cloned alongside:
```
~/Projects/
  plaza/        # main backend (consumes plazaql as mix + npm dep)
  plazaql/      # this repo
  plaza-docs/   # documentation site (consumes plazaql as npm dep)
```

## npm Package

Published as `@plazafyi/plazaql`. The `files` field in `package.json` controls what ships:

**Included**: `grammar.js`, `src/`, `queries/`, `tree-sitter.json`, `tree-sitter-plazaql.wasm`, `language-configuration.json`, `examples/`
**Excluded**: `lib/`, `test/`, `_build/`, `deps/`, `mix.exs`, `lsp/`

## Universal Rules

1. **grammar.js is the source of truth** — both parsers derive from it. Never let them diverge.
2. **Use make** — always use `make` targets for project commands.
3. **DRY** — search for existing patterns before implementing.
4. **No destructive git** — never use `git stash`, `git checkout --`, `git restore`, `git reset --hard`, or `git clean` without explicit user permission.
5. **Three test suites** — all three must pass before committing.
6. **Coordinate AST changes** — changing AST shape requires updating plaza's compiler too.
