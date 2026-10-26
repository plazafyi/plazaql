# Changelog

## 0.1.0 (unreleased)

First Hex release of the PlazaQL Elixir package.

### Language

- Parser (tree-sitter grammar, via the tree-sitter CLI), type checker with
  method-chain ordering, and formatter.
- Compiler from PlazaQL to `PlazaQL.Plan`: searches, spatial and tag filters,
  expression filters, computed columns, sort, `.cursor()`, aggregation and
  `group_by`, set operations, variables and output assignments, global
  directives, and computations (`route`, `isochrone`, `geocode`, ...).
- `mode: "motorcycle"` (alias `"motorbike"`) and `mode: "motor_scooter"`
  (aliases `"scooter"`, `"moped"`) for `route()`, `isochrone()` and
  `matrix()`, with the keywords `style`, `use_trails` and `use_curves`
  (motorcycle) and `use_primary` and `use_hills` (motor scooter). The type
  checker and the LSP reject them without their mode or out of range.
- `approaches:` on `route()`, one entry per point: `"curb"` reaches the
  point on the driving side (Plaza's `preferred_sides: "same"`),
  `"unrestricted"` is the default. The type checker and the LSP reject
  other values.
- `p["key"]` reads a property exactly as `t["key"]` reads a tag, anywhere an
  expression goes: `.filter()`, `.sort()`, `.group_by()`, the aggregates and
  `#filter()`, on OSM and dataset searches alike. Both compile to the same
  SQL. Syntax highlighting, LSP completions and hover cover it.
- The LSP accepts `.count()` after `.group_by()`, as the Elixir type checker
  already did.
- `gate_cost`, `toll_booth_cost` and `country_crossing_cost` for `route()`,
  `ev_route()` and `matrix()`: seconds (0-3600) added per gate, toll booth
  or border crossing passed. Like the other penalties they steer the route
  and leave `duration_s` alone.

### SQL generation

- `PlazaQL.query/2` and `PlazaQL.to_sql/2`: one parameterized PostGIS
  statement per plan. Several element types are a `UNION ALL` merged in sort
  order before the limit; counts and aggregates over several types are
  added up (averages weighted by rows); set operations are CTEs.
- `PlazaQL.SQL.branches/2`: one statement per element type or custom source,
  for callers that merge rows themselves.
- `PlazaQL.Schema`: table and column names, SRID, H3 cells and hash
  partitions (`caller_context`), extra full-output columns, admin boundaries
  and elevation rasters, and custom sources (`PlazaQL.Schema.Source`). Every
  identifier is validated; every value is a `$N` parameter.
- Rows are totally ordered (the sort, then the key columns) and sorted
  queries return `sort_key`; `Plan.seek` resumes after a row for keyset
  pagination.
- Computations and unresolved variable references return
  `{:error, %PlazaQL.NotCompilable{}}` for the caller to run or resolve.
