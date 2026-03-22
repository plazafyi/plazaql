# PlazaQL

A LINQ-style query language for geospatial data. PlazaQL provides a composable, chainable syntax for searching, filtering, routing, geocoding, and transforming OpenStreetMap data through the [Plaza API](https://plaza.fyi).

```
$$ = search(node, amenity: "cafe")
  .within(area("Manhattan, New York"))
  .around(200, point(40.7484, -73.9856))
  .fields("name", "cuisine", "opening_hours")
  .sort("name")
  .limit(10);
```

## File Extension

`.pql`

## Quick Examples

**Find restaurants near a point:**
```
$$ = search(node, amenity: "restaurant")
  .around(500, point(48.8566, 2.3522))
  .limit(20);
```

**Walking isochrone with nearby parks:**
```
$walkable = isochrone(center: point(40.71, -74.00), time: 15, mode: "walk");
$$.area = $walkable;
$$.parks = search(way, leisure: "park").within($walkable);
```

**Geocode and search nearby:**
```
$home = geocode("350 Fifth Avenue, New York");
$$ = search(node, shop: "supermarket")
  .around(500, $home)
  .sort("distance")
  .limit(5);
```

**Union two result sets and filter:**
```
$eating = search(node, amenity: "cafe").within($area)
        + search(node, amenity: "restaurant").within($area);
$$ = $eating.filter(wheelchair: "yes").limit(10);
```

---

## Table of Contents

- [Syntax Overview](#syntax-overview)
- [Comments](#comments)
- [Settings](#settings)
- [Variables](#variables)
- [Output Assignment](#output-assignment)
- [Type System](#type-system)
- [Functions](#functions)
- [Geometry Constructors](#geometry-constructors)
- [Methods](#methods)
- [Tag Filters](#tag-filters)
- [Set Operations](#set-operations)
- [Chain Ordering](#chain-ordering)
- [Argument Style](#argument-style)
- [Error Messages](#error-messages)
- [Grammar](#grammar)

---

## Syntax Overview

A PlazaQL query is a sequence of **statements**, each terminated by `;`. Statements are either:

- **Variable assignment:** `$name = expression;`
- **Output assignment:** `$$ = expression;` or `$$.name = expression;`

Expressions are built from **functions** (which produce values), **methods** (which transform values via chaining), and **operators** (union `+`, difference `-`).

```
// Variable — stores a value for reuse
$area = area("Berlin, Germany");

// Output — defines what gets returned
$$ = search(node, amenity: "cafe")
  .within($area)
  .limit(10);
```

An optional **settings block** `[key: value, ...]` can appear before all statements.

---

## Comments

```
// Line comment — everything after // is ignored

/* Block comment —
   can span multiple lines */
```

---

## Settings

An optional settings block at the top of the query controls execution parameters:

```
[timeout: 30, format: "geojson"]
```

| Setting   | Type     | Description                              |
|-----------|----------|------------------------------------------|
| `timeout` | integer  | Query timeout in seconds                 |
| `dataset` | string   | Dataset identifier                       |
| `format`  | string   | Output format: `"geojson"`, `"csv"`, `"xml"` |
| `maxsize` | integer  | Maximum response size in bytes           |

---

## Variables

Variables store intermediate values for reuse. Names start with `$` followed by a letter or underscore.

```
$center = point(40.7128, -74.0060);
$radius = 500;
$nyc = area("New York City");

// Use in subsequent expressions
$$ = search(node, amenity: "cafe")
  .around($radius, $center)
  .within($nyc);
```

Variables are immutable — once assigned, they cannot be reassigned.

---

## Output Assignment

Every query must have at least one `$$` assignment. This defines what gets returned.

**Single output:**
```
$$ = search(node, amenity: "cafe").limit(10);
```

**Named outputs** — return multiple result sets:
```
$$.cafes = search(node, amenity: "cafe").limit(5);
$$.parks = search(way, leisure: "park").limit(5);
$$.route = route(point(40.71, -74.00), point(40.75, -73.98));
```

---

## Type System

### Geometry Types

Value types used as arguments to spatial methods and constructors.

| Type         | Constructor                          | Description                    |
|--------------|--------------------------------------|--------------------------------|
| `Point`      | `point(lat, lng)`                    | Single coordinate              |
| `LineString`  | `linestring(p1, p2, ...)`           | Ordered sequence of points     |
| `Polygon`    | `polygon(p1, p2, p3, ...)`          | Closed ring of points          |
|              | `bbox(south, west, north, east)`    | Bounding box (shorthand)       |

### Feature Collection Types

Result sets returned by search and computation functions.

| Type         | Description                 | Produced by                                        |
|--------------|-----------------------------|----------------------------------------------------|
| `PointSet`   | Collection of point features | `search(node, ...)`, `geocode()`, `.centroid()`    |
| `LineSet`    | Collection of line features  | `search(way, ...)` with linear features            |
| `PolygonSet` | Collection of polygon features | `search(way, ...)` with area features, `.buffer()` |
| `GeoSet`     | Mixed collection (supertype) | `search(...)` without element type, mixed unions   |

### Computation Result Types

| Type        | Description                | Produced by                          | Usable as geometry? |
|-------------|----------------------------|--------------------------------------|---------------------|
| `Route`     | Line + steps/duration      | `route()`, `map_match()`, `optimize()` | Yes                |
| `Isochrone` | Travel-time polygon(s)     | `isochrone()`                        | Yes                 |
| `Area`      | Admin/named boundary       | `area()`                             | Yes                 |
| `Matrix`    | Distance/duration table    | `matrix()`                           | No (terminal)       |
| `Elevation` | Elevation data             | `elevation()`, `elevation_profile()` | No (terminal)       |
| `Scalar`    | Single numeric value       | `.count()`                           | No (terminal)       |

### Type Hierarchy

```
Geometry (usable as spatial argument)
├── Point
├── LineString
├── Polygon
├── Route        (geometry + result)
├── Isochrone    (geometry + result)
└── Area         (geometry + result)

GeoSet (chainable result sets)
├── PointSet
├── LineSet
└── PolygonSet

Terminal (not chainable)
├── Matrix
├── Elevation
└── Scalar
```

### Type Inference

```
// Geometry constructors
point(...)             → Point
linestring(...)        → LineString
polygon(...)           → Polygon
bbox(...)              → Polygon

// Search
search(node, ...)      → PointSet
search(way, ...)       → GeoSet
search(relation, ...)  → GeoSet
search(...)            → GeoSet          // no type = all

// Computations
area(...)              → Area
route(...)             → Route
isochrone(...)         → Isochrone
geocode(...)           → PointSet
reverse_geocode(...)   → PointSet
autocomplete(...)      → PointSet
text_search(...)       → PointSet
matrix(...)            → Matrix
map_match(...)         → Route
optimize(...)          → Route
ev_route(...)          → Route
elevation(...)         → Elevation
elevation_profile(...) → Elevation
nearest(...)           → PointSet

// Transforms that change type
.centroid()            :: GeoSet → PointSet
.buffer(n)             :: GeoSet → PolygonSet
.count()               :: GeoSet → Scalar

// Set operations
PointSet + PointSet       → PointSet
LineSet + LineSet         → LineSet
PolygonSet + PolygonSet   → PolygonSet
mixed + anything          → GeoSet
difference preserves left operand type
```

---

## Functions

### `search(element_type?, tag_filters...)`

Search for OpenStreetMap features by element type and tag filters.

```
search(node, amenity: "cafe")              // nodes with amenity=cafe
search(way, highway: "primary")            // ways with highway=primary
search(relation, boundary: "administrative") // relations
search(nwr, tourism: "museum")             // any element type
search(amenity: "cafe")                    // same as nwr (all types)
```

**Element types:** `node`, `way`, `relation`, `nwr` (all), `nw` (node+way), `nr` (node+relation), `wr` (way+relation)

### `area(name)`

Resolve a named administrative boundary or place.

```
$nyc = area("New York City");
$france = area("France");
$park = area("Central Park, New York");
```

Returns an `Area` which can be used as a geometry argument to `.within()`, `.intersects()`, etc.

### `route(points...) / route(from:, to:, mode:)`

Compute a route between points.

```
// Positional — drive by default
route(point(40.71, -74.00), point(40.75, -73.98))

// Keyword
route(from: point(40.71, -74.00), to: point(40.75, -73.98), mode: "walk")

// Multi-waypoint
route(point(40.71, -74.00), point(40.73, -73.99), point(40.75, -73.98))
```

**Modes:** `"drive"`, `"walk"`, `"bike"`

### `isochrone(center:, time:, mode:)`

Compute a travel-time polygon.

```
isochrone(center: point(40.71, -74.00), time: 15, mode: "walk")
```

| Parameter | Type    | Description                    |
|-----------|---------|--------------------------------|
| `center`  | Point   | Origin point                   |
| `time`    | integer | Travel time in minutes         |
| `mode`    | string  | `"drive"`, `"walk"`, `"bike"` |

### `geocode(address)`

Forward geocode — address string to point features.

```
geocode("1600 Pennsylvania Avenue, Washington DC")
```

### `reverse_geocode(point)`

Reverse geocode — coordinates to address.

```
reverse_geocode(point(38.8977, -77.0365))
```

### `autocomplete(text)`

Autocomplete partial place names.

```
autocomplete("Eiffel Tow")
```

### `text_search(query)`

Full-text search across place names and addresses.

```
text_search("pizza near Times Square")
```

### `nearest(point, tag_filters...)`

Find the nearest features to a point.

```
nearest(point(40.71, -74.00), amenity: "hospital")
```

### `matrix(points...)`

Compute a distance/duration matrix between multiple points.

```
matrix(point(40.71, -74.00), point(40.73, -73.99), point(40.75, -73.98))
```

### `map_match(linestring, mode:)`

Snap a GPS trace to the road network.

```
map_match(linestring(point(40.71, -74.00), point(40.72, -73.99)), mode: "drive")
```

### `optimize(points..., mode:)`

Solve the traveling salesman problem — optimal visit order.

```
optimize(point(40.71, -74.00), point(40.73, -73.99), point(40.75, -73.98), mode: "drive")
```

### `ev_route(from:, to:, mode:)`

EV-aware routing with charge stop planning.

```
ev_route(from: point(40.71, -74.00), to: point(42.36, -71.06), mode: "drive")
```

### `elevation(point)`

Look up elevation at a single point.

```
elevation(point(27.9881, 86.9250))
```

### `elevation_profile(linestring)`

Get elevation profile along a linestring.

```
elevation_profile(linestring(point(46.5, 6.6), point(46.0, 7.6)))
```

---

## Geometry Constructors

### `point(lat, lng)` / `point(lat:, lng:)`

```
point(40.7128, -74.0060)
point(lat: 40.7128, lng: -74.0060)
```

Note: PlazaQL uses `lat, lng` order (human convention). Internally converted to GeoJSON `[lng, lat]`.

### `linestring(p1, p2, ...)`

```
linestring(point(40.71, -74.00), point(40.73, -73.99), point(40.75, -73.98))
```

Minimum 2 points.

### `polygon(p1, p2, p3, ...)`

```
polygon(point(40.71, -74.01), point(40.71, -73.99), point(40.73, -73.99), point(40.73, -74.01))
```

Minimum 3 points. Automatically closed (first point repeated).

### `bbox(south, west, north, east)`

Shorthand for a rectangular polygon from bounding box coordinates.

```
bbox(40.70, -74.02, 40.75, -73.97)
```

### `circle(center, radius)`

```
circle(point(40.71, -74.00), 500)  // 500 meter radius
```

---

## Methods

Methods are chained onto expressions with `.method()` syntax. They are organized into phases (see [Chain Ordering](#chain-ordering)).

### Spatial Filters (Phase 3)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.within(geom)` | `GeoSet → GeoSet` | Features inside a geometry |
| `.around(distance, geom)` | `GeoSet → GeoSet` | Features within distance (meters) of a geometry |
| `.near(distance, geom)` | `GeoSet → GeoSet` | Like `.around()` but results sorted by distance |
| `.bbox(s, w, n, e)` | `GeoSet → GeoSet` | Features in bounding box |
| `.h3(cell)` | `GeoSet → GeoSet` | Features in H3 cell |
| `.intersects(geom)` | `GeoSet → GeoSet` | Features that intersect a geometry |
| `.contains(geom)` | `GeoSet → GeoSet` | Features that fully contain a geometry |
| `.crosses(geom)` | `GeoSet → GeoSet` | Features that cross a geometry |
| `.touches(geom)` | `GeoSet → GeoSet` | Features that touch a geometry |
| `.not_within(geom)` | `GeoSet → GeoSet` | Features NOT inside a geometry |
| `.not_intersects(geom)` | `GeoSet → GeoSet` | Features NOT intersecting a geometry |
| `.not_contains(geom)` | `GeoSet → GeoSet` | Features NOT containing a geometry |

```
search(node, amenity: "cafe")
  .within(area("Manhattan"))
  .around(200, point(40.74, -73.98));
```

### Tag Filter (Phase 3b)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.filter(tag_filters...)` | `GeoSet → GeoSet` | Apply tag filters post-search or post-union |

```
$combined = search(node, amenity: "cafe") + search(node, amenity: "restaurant");
$$ = $combined.filter(wheelchair: "yes", outdoor_seating: "yes");
```

### Transforms (Phase 4)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.buffer(meters)` | `GeoSet → PolygonSet` | Expand geometries by distance |
| `.simplify(meters)` | `GeoSet → GeoSet` | Reduce geometry complexity |
| `.centroid()` | `GeoSet → PointSet` | Convert to center points |

```
search(way, leisure: "park").buffer(100);    // 100m buffer around parks
search(way, boundary: *).simplify(1000);     // simplify to 1km tolerance
search(way, building: "yes").centroid();      // building center points
```

### Enrichments (Phase 5)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.elevation()` | `GeoSet → GeoSet` | Add elevation data to features |
| `.distance(point)` | `GeoSet → GeoSet` | Add distance from reference point |
| `.area()` | `GeoSet → GeoSet` | Compute area of polygon features |
| `.length()` | `GeoSet → GeoSet` | Compute length of linear features |

```
search(node, natural: "peak").elevation().sort("elevation");
search(node, amenity: "hospital").distance(point(40.71, -74.00)).sort("distance");
```

### Output Shape (Phase 6)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.fields(f1, f2, ...)` | `GeoSet → GeoSet` | Select specific tag fields |
| `.include(what)` | `GeoSet → GeoSet` | Include related data (`"nodes"`, `"members"`) |
| `.precision(n)` | `GeoSet → GeoSet` | Coordinate decimal places |

```
search(node, amenity: "cafe").fields("name", "cuisine", "opening_hours");
search(way, highway: "motorway").include("nodes");
search(node, amenity: *).precision(4);
```

### Ordering (Phase 7)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.sort(field)` | `GeoSet → GeoSet` | Sort results by field |
| `.limit(n)` | `GeoSet → GeoSet` | Maximum number of results |
| `.offset(n)` | `GeoSet → GeoSet` | Skip first n results |

```
search(node, amenity: "cafe").sort("name").limit(10).offset(20);
```

### Output Mode (Phase 8) — Terminal

| Method | Signature | Description |
|--------|-----------|-------------|
| `.count()` | `GeoSet → Scalar` | Return count only |
| `.ids()` | `GeoSet → GeoSet` | Return only feature IDs |
| `.tags()` | `GeoSet → GeoSet` | Return only tags (no geometry) |
| `.skel()` | `GeoSet → GeoSet` | Minimal geometry, no tags |

```
search(node, amenity: "cafe").within(area("Paris")).count();
search(node, shop: *).ids();
```

Only one output mode per chain. These are terminal — no further chaining allowed.

### Recursion

| Method | Signature | Description |
|--------|-----------|-------------|
| `.expand(:down)` | `GeoSet → GeoSet` | Recurse into relation members / way nodes |

```
search(relation, name: "Central Park").expand(:down);
```

---

## Tag Filters

Tag filters appear inside `search()` and `.filter()`. Seven filter types:

### Equals

```
amenity: "cafe"           // tags->>'amenity' = 'cafe'
```

### Not Equals

```
cuisine: !"fast_food"     // tags->>'cuisine' != 'fast_food'
```

### Regex

```
name: ~"^Starbucks"       // tags->>'name' ~ '^Starbucks'
```

### Case-Insensitive Regex

```
name: ~i"starbucks"       // tags->>'name' ~* 'starbucks'
```

### Negated Regex

```
name: !~"McDonald"        // NOT (tags->>'name' ~ 'McDonald')
```

### Exists

```
cuisine: *                // tags ? 'cuisine'
```

### Not Exists

```
name: !*                  // NOT tags ? 'name'
```

### Multiple Filters

Multiple filters in a single call are combined with AND:

```
search(node, amenity: "restaurant", cuisine: "italian", outdoor_seating: "yes")
// amenity=restaurant AND cuisine=italian AND outdoor_seating=yes
```

---

## Set Operations

### Union (`+`)

Combine two result sets:

```
$cafes = search(node, amenity: "cafe").within($area);
$restaurants = search(node, amenity: "restaurant").within($area);
$$ = $cafes + $restaurants;
```

### Difference (`-`)

Subtract one result set from another:

```
$all = search(node, amenity: ~"cafe|restaurant|fast_food").within($area);
$fast = search(node, amenity: "fast_food").within($area);
$$ = $all - $fast;
```

Type rules for set operations:
- Same types preserve the type: `PointSet + PointSet → PointSet`
- Mixed types produce `GeoSet`: `PointSet + LineSet → GeoSet`
- Difference preserves the left operand's type

---

## Chain Ordering

Methods must follow a specific phase order. Methods within the same phase can appear in any order, but later phases cannot precede earlier phases.

```
Phase 1: Source        search() | area() | route() | isochrone() | ...
Phase 2: Set ops       + | -
Phase 3: Spatial       .within() | .around() | .bbox() | .near() | .h3() |
                       .intersects() | .contains() | .crosses() | .touches() |
                       .not_within() | .not_intersects() | .not_contains()
Phase 3b: Tag filter   .filter()
Phase 4: Transforms    .buffer() | .simplify() | .centroid()
Phase 5: Enrichments   .elevation() | .distance() | .area() | .length()
Phase 6: Output shape  .fields() | .include() | .precision()
Phase 7: Ordering      .sort() | .limit() | .offset()
Phase 8: Output mode   .count() | .ids() | .tags() | .skel()
```

**Valid:**
```
search(node, amenity: "cafe").within($area).sort("name").limit(10);
```

**Invalid** — `.limit()` (Phase 7) before `.within()` (Phase 3):
```
search(node, amenity: "cafe").limit(10).within($area);  // ERROR
```

---

## Argument Style

All functions and methods support **keyword** and **positional** arguments. You cannot mix styles in a single call.

```
// Keyword (self-documenting)
.around(distance: 500, geometry: point(lat: 40.71, lng: -74.00))

// Positional (concise)
.around(500, point(40.71, -74.00))
```

---

## Error Messages

PlazaQL provides structured error messages with source location, description, and actionable hints.

### Parse Error

```
error: unexpected token
  --> query:3:15
   |
 3 | $$ = search(node amenity: "cafe");
   |                   ^^^^^^^ expected ',' between arguments
   |
   = hint: add a comma: search(node, amenity: "cafe")
```

### Type Error

```
error: method .within() requires a geometry argument, got Scalar
  --> query:5:3
   |
 5 |   .within(42)
   |           ^^ expected Point, LineString, Polygon, Area, Route, or Isochrone
   |
   = hint: use a geometry constructor: .within(point(40.71, -74.00))
```

### Chain Order Error

```
error: .limit() (phase 7) cannot appear before .within() (phase 3)
  --> query:2:3
   |
 2 |   .limit(10)
   |   ^^^^^^^^^^ phase 7: ordering
 3 |   .within($area)
   |   -------------- phase 3: spatial (must come first)
   |
   = hint: move .limit(10) after .within($area)
```

### Undefined Variable

```
error: undefined variable $downtown
  --> query:4:12
   |
 4 |   .within($downtown)
   |           ^^^^^^^^^ not defined
   |
   = hint: assign it first: $downtown = area("Downtown");
```

---

## Grammar

### EBNF

```ebnf
program        = settings? statement+ ;
settings       = "[" setting ("," setting)* "]" ;
setting        = IDENT ":" value ;

statement      = var_assign | out_assign ;
var_assign     = "$" IDENT "=" expression ";" ;
out_assign     = "$$" ("." IDENT)? "=" expression ";" ;

expression     = set_expr ;
set_expr       = unary_expr (("+" | "-") unary_expr)* ;
unary_expr     = primary method_chain? ;

primary        = search | area_call | route_call | isochrone_call
               | geocode_call | reverse_geocode_call | autocomplete_call
               | text_search_call | matrix_call | map_match_call
               | optimize_call | ev_route_call | elevation_call
               | elevation_profile_call | nearest_call
               | constructor | variable | "(" expression ")" ;

search         = "search" "(" (element_type ",")? tag_filters ")" ;
area_call      = "area" "(" STRING ")" ;
route_call     = "route" "(" arg_list ")" ;
isochrone_call = "isochrone" "(" arg_list ")" ;
geocode_call   = "geocode" "(" STRING ")" ;
/* ... other function calls follow the same pattern */

constructor    = point | linestring | polygon | bbox | circle ;
point          = "point" "(" arg_list ")" ;
linestring     = "linestring" "(" arg_list ")" ;
polygon        = "polygon" "(" arg_list ")" ;
bbox           = "bbox" "(" NUMBER "," NUMBER "," NUMBER "," NUMBER ")" ;
circle         = "circle" "(" arg_list ")" ;

method_chain   = ("." method_call)+ ;
method_call    = IDENT "(" arg_list? ")" ;

arg_list       = keyword_args | positional_args ;
keyword_args   = keyword_arg ("," keyword_arg)* ;
keyword_arg    = IDENT ":" value ;
positional_args= value ("," value)* ;

tag_filters    = tag_filter ("," tag_filter)* ;
tag_filter     = IDENT ":" tag_value ;
tag_value      = STRING | "!" STRING | "~" STRING | "~i" STRING
               | "!~" STRING | "*" | "!*" ;

element_type   = "node" | "way" | "relation" | "nwr" | "nw" | "nr" | "wr" ;

value          = STRING | NUMBER | BOOL | constructor | variable
               | ":" IDENT ;
variable       = "$" IDENT ;

STRING         = '"' ( ~["\\\n] | '\\' . )* '"' ;
NUMBER         = "-"? [0-9]+ ("." [0-9]+)? ;
BOOL           = "true" | "false" ;
IDENT          = [a-zA-Z_] [a-zA-Z0-9_]* ;

COMMENT        = "//" ~[\n]* | "/*" .*? "*/" ;
```

---

## GeoJSON Conventions

- PlazaQL uses **lat, lng** order in constructors (human convention): `point(40.71, -74.00)`
- Internally, coordinates are stored as GeoJSON **[lng, lat]**
- All API responses are GeoJSON FeatureCollections
- Computation results (routes, isochrones) include both geometry and metadata properties

---

## License

MIT — see [LICENSE](./LICENSE).
