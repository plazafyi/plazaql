# The PlazaQL compiler

This document describes how the Elixir package turns PlazaQL source into
SQL, and what is left for the application that runs it. The README section
"Using the Elixir library" covers the API from the user's side.

## Pipeline

```
source string
  → PlazaQL.Parser.parse/1          AST (tree-sitter CLI, CST → tuples)
  → PlazaQL.TypeChecker.check/1     validated AST (types, method order)
  → PlazaQL.Compiler.compile/2      %{plans, steps, output_names}
  → PlazaQL.SQL.to_sql/2            one %PlazaQL.Query{sql, params}
    or PlazaQL.SQL.branches/2       [{branch, %PlazaQL.Query{}}]
```

`PlazaQL.query/2` is the short path: parse, check, compile, and `to_sql/2`
of the first plan.

`compile/2` returns one `PlazaQL.Plan` per output (`plans`), and every named
statement in order (`steps`, `[{name, plan}]`). A program with variables
runs its steps in order: a later step can reference an earlier one.

## Plans

`PlazaQL.Plan` is the intermediate representation. A search plan holds
element types, tag filters, spatial filters (`spatial_filter` plus
`spatial_filters`, all ANDed, and `scope_geometry` from `#within`), metadata
filters, expression filters, output mode and options, computed columns,
sort, limit, offset, aggregation (`group_by`, `aggregate_expr`), set
operations and sources. A computation plan (`kind: :computation`) holds
`{type, params}` for a route, isochrone, geocode and so on.

Some plan fields are for the caller and SQL generation ignores them:
`cursor` (an opaque token from the server), `recurse`, `narrow`,
`member_filter` and `tile`.

## What SQL generation needs resolved first

The compiler leaves references it cannot resolve without data:

| In the plan | Comes from | Resolve to |
| --- | --- | --- |
| `{:predicate, p, {:set_ref, name}}` | `.within($var)` etc. | `{:predicate, p, {:ewkt, ewkt}}` |
| `{:around_set, name, r}` | `.around(r, $var)` | `{:around_set_resolved, ewkts, r}` |
| `{:boundary_set, name}` | plans a caller builds | `{:polygon, ring}` |
| `{:bracket_eq, key, set, attr}` | `$set[attr]` | `{:eq, key, v}` or `{:any_of, key, vs}` |
| `{:geom_func, :distance, {:set_ref, name}, pos}` | `distance($var)` of a search | `{:geom_func, :distance, {:ewkt, ewkt}, pos}` |
| `{:geom_func, :overlap_fraction, {:set_ref, name}, pos}` | `overlap_fraction($var)` | `{:geom_func, :overlap_fraction, {:ewkt, ewkt}, pos}` |

Any of them left in a plan makes `to_sql/2` return
`{:error, %PlazaQL.NotCompilable{}}`, as computations do.

## SQL generation

`PlazaQL.SQL` is the public entry. Internally:

| Module | Builds |
| --- | --- |
| `PlazaQL.SQL.Branch` | A branch: an element type's table or a custom source, with its keys, columns and rank. Binds `type()` to the branch's type. |
| `PlazaQL.SQL.Builder` | One `SELECT` for a branch: columns by output mode, WHERE, GROUP BY, ORDER BY, LIMIT, OFFSET. |
| `PlazaQL.SQL.Where` | Spatial, tag, metadata, id, expression, H3, partition, keyset and custom conditions. |
| `PlazaQL.SQL.Expression` | The expression language (`t["k"]`, arithmetic, `length()`, `distance(...)`, ...). |
| `PlazaQL.SQL.Sort` | The sort: ORDER BY, the `sort_key` column, and the keyset condition. |

Every builder threads `{sql, params, next_index}`, so parameters are
numbered as they are added. Values are always parameters. Identifiers come
from `PlazaQL.Schema`, which validates them against `^[a-z_][a-z0-9_]*$`.

### Branches and ranks

A plan reads its element types and then its sources (`plan.sources`), in
that order; a branch's index in that list is its rank. `:boundary` reads the
relations table and adds `tags ? 'boundary'`.

`to_sql/2` joins the branches into one statement. `branches/2` returns one
statement per branch, for callers whose branches select different columns
or who run branches separately.

### Order and pagination

Every row query is totally ordered: by the sort, then by the branch's key
columns (`osm_id`, or a source's `keys`). A sorted query also selects the
sort value as `sort_key`. Rows of several branches merge on
`(sort_key, rank, keys)`. In `to_sql/2` that merge is an outer `ORDER BY`
over the `UNION ALL`. Each branch fetches its first `offset + limit` rows,
and the outer query applies the limit and offset once.

`plan.seek = {sort_value, rank, keys}` is the last row of the previous
page. Each branch adds the condition that keeps only rows after it: a branch
ranked before the cursor's keeps rows with a later sort value, the cursor's
own branch also keeps equal values with a greater key, and a later branch
keeps equal values too. Nulls sort last ascending and first descending, as
in Postgres.

### Output modes

| Mode | Columns |
| --- | --- |
| `:full` | keys, tags, geometry (after simplify, buffer, centroid), `full_columns` |
| `:tags` | keys, tags |
| `:skel` | keys, geometry |
| `:ids` | keys |
| `:keys` | keys, plus the partition key on partitioned tables |
| `:count` | `COUNT(*) AS cnt` (`group_key` first when grouped) |
| `:sum`, `:min`, `:max` | `value`, in the expression's own type |
| `:avg` | `avg_val` and `cnt`, so averages over branches can be weighted |

Every branch also selects its label as `__type__`, and row modes add
computed columns (`distance_m`, `area_m2`, `length_m`, `elevation_m`,
`overlap_fraction`) and `sort_key`. Grouped queries group by position
(`GROUP BY 1`).

### Spatial filters

| Filter | SQL |
| --- | --- |
| `{:bbox, s, w, n, e}` | `geom && ST_MakeEnvelope(...)`, two envelopes across the antimeridian |
| `{:around, lat, lng, r}` | `ST_DWithin(geom::geography, ST_Point(...)::geography, r)` |
| `{:h3, cell}` | `tile_id <@ cell OR tile_id @> cell` |
| `{:polygon, ring}` | `ST_Within(geom, ST_GeomFromText(...))` |
| `{:predicate, p, geometry}` | `ST_CoveredBy` (within), `ST_Intersects`, `ST_Contains`, `ST_Crosses`, `ST_Touches`, or their negations |
| `{:predicate, p, geometry, radius}` | the same against the geometry buffered by `radius` meters; `:around` is `ST_DWithin` |
| `{:around_set_resolved, ewkts, r}` | bounding-box prefilter, then `ST_DWithin` to the collection |

### Caller context

`plan.caller_context` carries what the caller precomputed:

- `h3_tiles: [cell]` adds an H3 containment prefilter for the SP-GiST
  index, skipped above `schema.limits.max_h3_tiles` cells.
- `partitions: [key]` or `%{element_type => [key]}` adds
  `partition_tile_id = ANY($n::bigint[])` on partitioned tables.

### Sources

A source (`PlazaQL.Schema.Source`) is a table of features with its own key
columns, a jsonb column filters read (`filter_tags`), and two options:
`typed_values` (an equality filter also matches the number or boolean the
string spells, using `@>` so a GIN index can serve it) and `sparse_tile_id`
(rows too large for one H3 cell have a NULL tile id and are matched by
geometry). Element ids, metadata filters and partitions don't apply to
sources. A custom clause given as `{source_name, sql, params}` applies to
that source only.

### Set operations and aggregation

In `to_sql/2`, `a + b`, `a - b` and `a & b` become a `base` CTE plus one CTE
per operand, combined with `UNION`, `NOT EXISTS` or `EXISTS` on
`(id, __type__)`. Operations apply left to right to the running result:
`a + b - c` is `(a + b) - c`, with the intermediate result as a
`combined_N` CTE. An operand that is itself a combination (`a + (b - c)`)
compiles to a nested `WITH`. An operand without a spatial filter inherits
its parent's.
Counts and aggregates over several branches wrap the branches in an outer
query: `SUM(cnt)`, `SUM/MIN/MAX(value)`, or a row-weighted average.

## How Plaza uses it

The Plaza API runs plans with its own orchestration
(`Plaza.Query.Executor`): it resolves variables between steps, combines set
operations over element identities, merges branches and dataset features,
and dispatches computations to its services. It calls `branches/2` for every
query it sends to the database, with a schema that adds H3 tiles, hash
partitions and dataset features as a source.
