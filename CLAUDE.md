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

Always use `make` targets. Never run `mix` or `npm` directly.

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
  → SQL.to_sql/2             (one parameterized statement + params)
    or SQL.branches/2        (one statement per element type / source)
```

`docs/compiler.md` is the architecture reference (references the caller
resolves, branches and ranks, ordering and keyset pagination, output modes,
spatial filter SQL, sources). The README's "Using the Elixir library"
section is the user guide; `test/plazaql/library_usage_test.exs` runs its
examples.

### Key Modules

| Module | Purpose |
|--------|---------|
| `PlazaQL.Compiler` | AST → `Plan` IR. Walks top-level nodes (outputs, variables, directives) and compiles expressions into Plans. |
| `PlazaQL.Plan` | The intermediate representation. A struct capturing element types, tag filters, spatial filters, set operations, output mode, computed columns, etc. |
| `PlazaQL.Plan.OutputOptions` | Geometry transforms (simplify, buffer, centroid) and result formatting (fields, sort, precision). |
| `PlazaQL.Schema` | Configurable target database schema — table names, column names, SRID, extensions, partitioned tables, extra full-output columns, custom sources. Defaults to standard OSM. Validates every identifier. |
| `PlazaQL.Schema.Source` | A custom feature table queried like an element type (own keys, filter column, typed JSON values, sparse H3 tiles). |
| `PlazaQL.SQL` | Top-level SQL generation. `to_sql/2`: UNION ALL (merged in sort order), aggregation wrappers, or CTE-based set operations. `branches/2`: one query per branch. |
| `PlazaQL.SQL.Branch` | Internal. A branch (element type table or source) with its keys, columns and rank; binds `type()`. |
| `PlazaQL.SQL.Builder` | Internal. Assembles a complete SELECT for one branch — columns, WHERE, GROUP BY 1, ORDER BY, LIMIT/OFFSET. |
| `PlazaQL.SQL.Where` | Internal. Builds WHERE from spatial, tag, metadata, id and expression filters, H3 tiles, partitions, keyset seek and custom clauses. |
| `PlazaQL.SQL.Expression` | Internal. Converts expression AST nodes (binary ops, tag access, geometry functions, literals) to SQL fragments. |
| `PlazaQL.SQL.Sort` | Internal. The sort: ORDER BY (sort, then keys), the `sort_key` column, the keyset condition. |
| `PlazaQL.Query` | Result struct — holds `sql`, `params`, and optional `plan` reference. |
| `PlazaQL.NotCompilable` | Error for computation plans (route, isochrone, etc.) that can't become SQL and need a service backend. |

### SQL Generation Patterns

- **UNION ALL**: Multi-type queries (e.g. `nwr`) generate one SELECT per element type joined with UNION ALL.
- **CTEs for set ops**: Union (`+`), difference (`-`), intersection (`&`) use `WITH` clauses — `base` CTE plus one CTE per operand.
- **Aggregation wrappers**: Cross-type aggregations (count, sum, avg, etc.) wrap the UNION ALL in an outer SELECT that merges per-type results.
- **Accumulator pattern**: All SQL modules thread `{sql, params, next_idx}` through every build step, ensuring correct `$N` parameter numbering without mutation.
- **Total order**: Row queries order by the sort, then the branch's key columns, and select `sort_key` when sorted. Branches merge on `(sort_key, rank, keys)`; `Plan.seek` resumes after a row in that order.
- **Caller resolution**: Variables (`{:set_ref, _}`, `{:around_set, ...}`, `$x[attr]`) and computations are not SQL; they return `NotCompilable` until the caller resolves them (e.g. to `{:ewkt, _}` geometries).
- **Plaza parity**: The plaza server executes every database query through `branches/2`. Its behavioral test suite (REST vs `/query` parity, cursors, datasets, aggregates) is the integration test for SQL changes here: run it with `PLAZAQL_PATH` pointing at this checkout.

## How It's Consumed

| Consumer | Mechanism | What it uses |
|----------|-----------|-------------|
| **plaza** (backend) | `{:plazaql, git: ...}` mix dep (`PLAZAQL_PATH` for a local checkout) | Parser, type checker, formatter, compiler, and the SQL generator (`PlazaQL.SQL.branches/2`) for every query it runs |
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

Both WASM copies (`tree-sitter-plazaql.wasm` and `lsp/src/tree-sitter-plazaql.wasm`)
must be rebuilt too. If `tree-sitter build --wasm` fails with `stdlib.h` not
found (wasi-sdk 34 dropped the `wasm32-wasi` target the 0.26 CLI asks for),
build the side module with the cached SDK; this reproduces the committed
file byte for byte:

```bash
W=~/.cache/tree-sitter/wasi-sdk
$W/bin/clang --target=wasm32-wasip1 --sysroot=$W/share/wasi-sysroot -fPIC -shared -Os \
  -fvisibility=hidden -Wl,--export=tree_sitter_plazaql -Wl,--allow-undefined \
  -Wl,--no-entry -nostdlib -I src src/parser.c -o tree-sitter-plazaql.wasm
cp tree-sitter-plazaql.wasm lsp/src/tree-sitter-plazaql.wasm
```

The tree-sitter 0.27.1 CLI builds the same file byte for byte without the
manual clang step. The repo's `node_modules/.bin/tree-sitter` is 0.26.13 (the
one that fails). The 0.27.1 CLI is the global npm install under asdf nodejs
23.4.0, which this repo's `.tool-versions` (nodejs 24.14.1) hides, so select
it explicitly:

```bash
export ASDF_NODEJS_VERSION=23.4.0   # tree-sitter --version -> 0.27.1
tree-sitter generate
tree-sitter build --wasm -o tree-sitter-plazaql.wasm
cp tree-sitter-plazaql.wasm lsp/src/tree-sitter-plazaql.wasm
```

Without `ASDF_NODEJS_VERSION`, the `tree-sitter` shim reports "No version is
set" and `make test` (which runs `tree-sitter test`) fails, and so does the
Elixir parser, which shells out to the same CLI.

`tree-sitter generate` writes `src/grammar.json` and `src/node-types.json`
without a trailing newline; the `end-of-file-fixer` hook adds it back. Commit
the fixed files, or the next precommit run rewrites them.

The Elixir parser uses the library cached at `~/.cache/tree-sitter/lib/plazaql.dylib`
when it exists, which every checkout on the machine shares. To test a grammar
branch without replacing it, build the library elsewhere and point
`PLAZAQL_TREE_SITTER_LIB` at it (set `TREE_SITTER_LIBDIR` too, so
`tree-sitter test` compiles into the same place):

```bash
clang -dynamiclib -fPIC -O2 -I src src/parser.c -o /tmp/ts/plazaql.dylib
PLAZAQL_TREE_SITTER_LIB=/tmp/ts/plazaql.dylib TREE_SITTER_LIBDIR=/tmp/ts make test
```

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
3. **LSP tests** (`cd lsp && npx vitest run`) — parser, type-checker, completions, osm-tags (184 tests)

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
