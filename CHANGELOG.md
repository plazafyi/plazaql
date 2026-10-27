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
- `lane_splitting:` (motorcycle): a rider who filters between lanes of
  queued traffic, as Plaza's REST `motorcycle.lane_splitting`. The type
  checker and the LSP check it is `true` or `false` and needs
  `mode: "motorcycle"`.
- `ev_route()` takes `mode: "motorcycle"` and `"motor_scooter"` with their
  rider keywords (electric motorcycles and scooters); bicycle and walker
  keywords are rejected there.
- `ev_route()` takes `mode: "truck"` with the truck keywords (`height:`,
  `weight:`, `hazmat:`, ...): an electric truck, as Plaza's `POST /route`
  with `ev` and `mode: "truck"`.
- `exclude: "cash_only_tolls"` (roads through toll booths that take only
  cash), and `isochrone()` and `matrix()` take `exclude` like `route()`.
- `datasets:` on `route()`, `ev_route()`, `isochrone()`, `matrix()` and
  `map_match()`: datasets whose roads Plaza routes over as well as OSM's
  (REST `datasets` on the routing endpoints). `avoid_datasets:` stays the
  areas to keep out of. LSP signatures list it.
- `datasets:` on `optimize()`, `centroid()`, `expansion()` and `nearest()`
  too, as on Plaza's REST endpoints.
- `centroid()`, `expansion()`, `optimize()` and `map_match()` take
  `avoid_datasets:` like `route()`, `isochrone()` and `matrix()`.
- `map_match()` and `optimize()` take `exclude:` like `route()`, checked
  the same way (Plaza's REST `exclude` on `/map-match` and `/optimize`).
- `optimize()`, `centroid()`, `expansion()` and `map_match()` take every
  vehicle mode too: the truck keywords with `mode: "truck"` and the bicycle,
  pedestrian, motorcycle and scooter keywords with their modes, as
  `route()`, `isochrone()` and `matrix()` do. LSP signatures list them.
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
- The pedestrian options (`walking_speed:`, `use_hills:`, `use_lit:`,
  `walkway_factor:`, `sidewalk_factor:`, `step_penalty:`,
  `max_hiking_difficulty:`) type-check on `route()` and `isochrone()` with
  `mode: "transit"`, for the journey's walking legs.
- `arrive_by:` on `route()` and `wheelchair:` on `route()` and
  `isochrone()` with `mode: "transit"`. `arrive_by` finds the latest
  departure that arrives by then; `wheelchair` rides only accessible trips
  and uses only accessible stops (it stays the pedestrian option with
  `mode: "foot"`). The type checker and the LSP reject `arrive_by` with
  `depart_at`, on `isochrone()`, as `"now"` or a non-string, and either
  keyword with another mode.

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
