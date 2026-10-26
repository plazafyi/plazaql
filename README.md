# PlazaQL

A LINQ-style query language for geospatial data. PlazaQL provides a composable, chainable syntax for searching, filtering, routing, geocoding, and transforming OpenStreetMap data through the [Plaza API](https://plaza.fyi).

```plazaql
search(node, amenity: "cafe")
  .within(boundary(name: "Manhattan, New York"))
  .around(200, point(40.7484, -73.9856))
  .fields("name", "cuisine", "opening_hours")
  .sort(t["name"])
  .limit(10);
```

## File Extension

`.pql`

## Quick Examples

**Find restaurants near a point:**
```plazaql
search(node, amenity: "restaurant")
  .around(500, point(48.8566, 2.3522))
  .limit(20);
```

**Walking isochrone with nearby parks:**
```plazaql
$$.area = isochrone(center: point(40.71, -74.00), time: 900, mode: "foot");
$$.parks = search(way, leisure: "park").within($$.area);
```

**Geocode and search nearby:**
```plazaql
$home = geocode("350 Fifth Avenue, New York");
search(node, shop: "supermarket")
  .around(500, $home)
  .sort(distance($home))
  .limit(5);
```

**Expression filter and aggregation:**
```plazaql
search(way, building: "yes")
  .within(boundary(name: "Manhattan, New York"))
  .filter(is_number(t["height"]) && number(t["height"]) > 50)
  .group_by(t["building"])
  .count();
```

**Global directive scoping:**
```plazaql
#within(geometry: boundary(name: "Berlin"));
#filter(wheelchair: "yes");

$$.cafes = search(node, amenity: "cafe").limit(10);
$$.restaurants = search(node, amenity: "restaurant").limit(10);
```

---

## Table of Contents

- [Syntax Overview](#syntax-overview)
- [Comments](#comments)
- [Variables](#variables)
- [Output Assignment](#output-assignment)
- [Type System](#type-system)
- [Functions](#functions)
- [Geometry Constructors](#geometry-constructors)
- [Methods](#methods)
- [Tag Filters](#tag-filters)
- [Set Operations](#set-operations)
- [Global Directives](#global-directives)
- [Expression Language](#expression-language)
- [Aggregation](#aggregation)
- [Chain Ordering](#chain-ordering)
- [Argument Style](#argument-style)
- [Error Messages](#error-messages)
- [Grammar](#grammar)

---

## Syntax Overview

A PlazaQL query is a sequence of **statements**, each terminated by `;`. Statements are either:

- **Bare expression:** `expression;` (implicit output)
- **Variable assignment:** `$name = expression;`
- **Output assignment:** `$$ = expression;` or `$$.name = expression;`
- **Global directive:** `#method(args);` (applies to all subsequent queries)

Expressions are built from **functions** (which produce values), **methods** (which transform values via chaining), and **operators** (union `+`, difference `-`, intersection `&`).

```plazaql
// Variable — stores a value for reuse
$area = boundary(name: "Berlin, Germany");

// Bare expression — implicitly becomes the output
search(node, amenity: "cafe")
  .within($area)
  .limit(10);
```

---

## Comments

```plazaql
// Line comment — everything after // is ignored

/* Block comment —
   can span multiple lines */

/* Nested comments are supported —
   /* inner comment */
   still inside the outer comment */
```

---

## Variables

Variables store intermediate values for reuse. Names start with `$` followed by a letter or underscore.

```plazaql
$center = point(40.7128, -74.0060);
$radius = 500;
$nyc = boundary(name: "New York City");

// Use in subsequent expressions
search(node, amenity: "cafe")
  .around($radius, $center)
  .within($nyc);
```

Variables are immutable — once assigned, they cannot be reassigned.

Named output variables (`$$.name`) can also be used as values in later expressions — see [Output Assignment](#output-assignment).

---

## Output Assignment

Every query must produce at least one output. This defines what gets returned.

**Single output** — bare expression (preferred):
```plazaql
search(node, amenity: "cafe").limit(10);
```

A bare expression statement is equivalent to `$$ = expression;`. The explicit `$$ =` prefix is supported but optional for single-output queries:
```plazaql
$$ = search(node, amenity: "cafe").limit(10);
```

**Named outputs** — return multiple result sets:
```plazaql
$$.cafes = search(node, amenity: "cafe").limit(5);
$$.parks = search(way, leisure: "park").limit(5);
$$.route = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98));
```

**Named output references** — `$$.name` values can be referenced in later statements, eliminating the need for intermediate variables:
```plazaql
$$.route = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98));
$$.stops = search(node, amenity: "cafe").around(200, $$.route);
```

This is equivalent to the more verbose:
```plazaql
$r = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98));
$$.route = $r;
$$.stops = search(node, amenity: "cafe").around(200, $r);
```

Named outputs are immutable — once assigned, they cannot be reassigned.

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
| `PointSet`   | Collection of point features | `search(node, ...)`, `geocode()`, `place_lookup()`, `.centroid()` |
| `LineSet`    | Collection of line features  | `search(way, ...)` with linear features            |
| `PolygonSet` | Collection of polygon features | `search(way, ...)` with area features, `.buffer()` |
| `GeoSet`     | Mixed collection (supertype) | `search(...)` without element type, mixed unions   |

### Computation Result Types

| Type        | Description                | Produced by                          | Usable as geometry? |
|-------------|----------------------------|--------------------------------------|---------------------|
| `Route`     | Line + steps/duration      | `route()`, `map_match()`, `optimize()` | Yes                |
| `Isochrone` | Travel-time polygon(s)     | `isochrone()`                        | Yes                 |
| `Boundary`  | Admin/named boundary       | `boundary()`                         | Yes                 |
| `Matrix`    | Distance/duration table    | `matrix()`                           | No (terminal)       |
| `Elevation` | Elevation data             | `elevation()`, `elevation_profile()` | No (terminal)       |
| `Scalar`    | Single numeric value       | `.count()`, `.sum()`, `.min()`, `.max()`, `.avg()` | No (terminal)       |

### Special Types

| Type         | Description                          | Produced by                          |
|--------------|--------------------------------------|--------------------------------------|
| `GeoElement` | Single element from a set            | `.first()`, `.last()`, `.index(n)` — usable as geometry |
| `ValueSet`   | Tag values from a set (ANY semantics) | `$set[attr]` — bracket ref on a GeoSet |
| `GroupedSet` | Partitioned set awaiting aggregation | `.group_by(expr)` — only aggregation methods allowed after |

### Type Hierarchy

```
Geometry (usable as spatial argument)
├── Point
├── LineString
├── Polygon
├── Route        (geometry + result)
├── Isochrone    (geometry + result)
├── Boundary     (geometry + result)
└── GeoElement   (single element from a set)

GeoSet (chainable result sets)
├── PointSet
├── LineSet
└── PolygonSet

Derived
├── ValueSet     (tag values from bracket ref)
└── GroupedSet   (partitioned set, accepts only aggregation)

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
boundary(...)          → Boundary
route(...)             → Route
isochrone(...)         → Isochrone
geocode(...)           → PointSet
place_lookup(...)      → PointSet
reverse_geocode(...)   → PointSet
autocomplete(...)      → PointSet
matrix(...)            → Matrix
map_match(...)         → Route
optimize(...)          → Route
ev_route(...)          → Route
elevation(...)         → Elevation
elevation_profile(...) → Elevation
nearest(...)           → PointSet
centroid(...)          → PointSet
expansion(...)         → LineSet
dataset(...)           → (search source, not a standalone type)

// Transforms that change type
.centroid()            :: GeoSet → PointSet
.buffer(n)             :: GeoSet → PolygonSet
.first()               :: GeoSet → GeoElement
.last()                :: GeoSet → GeoElement
.index(n)              :: GeoSet → GeoElement
.group_by(expr)        :: GeoSet → GroupedSet
.count()               :: GeoSet | GroupedSet → Scalar
.sum(expr)             :: GeoSet | GroupedSet → Scalar
.min(expr)             :: GeoSet | GroupedSet → Scalar
.max(expr)             :: GeoSet | GroupedSet → Scalar
.avg(expr)             :: GeoSet | GroupedSet → Scalar

// Bracket refs
$element[attr]         :: GeoElement → scalar value (equality match)
$set[attr]             :: GeoSet → ValueSet (ANY semantics)

// Set operations
PointSet + PointSet       → PointSet
LineSet + LineSet         → LineSet
PolygonSet + PolygonSet   → PolygonSet
mixed + anything          → GeoSet
difference preserves left operand type
same & same               → same type
mixed & mixed             → GeoSet
```

---

## Functions

Each computation (`route()`, `geocode()`, `matrix()`, ...) accepts only the keywords listed in its table below, the parameters of the REST endpoint it stands in for. Any other keyword is a type error that names the computation and lists the keywords it takes, for example "`route()` does not accept `points:`". Positional arguments a computation has no use for are errors too; they are never dropped.

### `search(element_type?, tag_filters...)`

Search for OpenStreetMap features by element type and tag filters.

```plazaql
search(node, amenity: "cafe")              // nodes with amenity=cafe
search(way, highway: "primary")            // ways with highway=primary
search(relation, boundary: "administrative") // relations
search(nwr, tourism: "museum")             // any element type
search(amenity: "cafe")                    // same as nwr (all types)
```

**Element types:** `node`, `way`, `relation`, `nwr` (all)

### `boundary(name:)`

Resolve a named administrative boundary or place.

```plazaql
$nyc = boundary(name: "New York City");
$france = boundary(name: "France");
$park = boundary(name: "Central Park, New York");
```

Returns a `Boundary` which can be used as a geometry argument to `.within()`, `.intersects()`, etc.

### `route(origin:, destination:, mode:)`

Compute a route between points.

```plazaql
// Keyword (preferred)
route(origin: point(40.71, -74.00), destination: point(40.75, -73.98))

// With mode
route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), mode: "foot")
```

**Modes:** `"auto"`, `"foot"`, `"bicycle"`, `"truck"`

| Parameter       | Type            | Description                                                                 |
|-----------------|-----------------|-----------------------------------------------------------------------------|
| `origin`        | Point           | Start point                                                                 |
| `destination`   | Point           | End point                                                                   |
| `mode`          | string          | `"auto"`, `"foot"`, `"bicycle"`, `"truck"` (optional)                       |
| `waypoints`     | Point[]         | Points to visit in order (optional)                                         |
| `alternatives`  | number          | Number of alternative routes to return (optional)                           |
| `steps`         | boolean         | Include turn-by-turn steps (optional)                                       |
| `overview`      | string/false    | Route geometry detail: `"full"` (default), `"simplified"`, or `false` for none (optional) |
| `geometries`    | string          | Geometry encoding: `"geojson"` (default), `"polyline"`, `"polyline6"` (optional) |
| `annotations`   | boolean         | Per-edge duration and distance arrays (optional)                            |
| `depart_at`     | string          | ISO 8601 departure time or `"now"`, for time-of-day traffic (optional)      |
| `traffic_model` | string          | `"best_guess"` (default), `"optimistic"`, `"pessimistic"`; needs `depart_at` (optional) |
| `exclude`       | string[]/string | Road types to avoid: `"toll"`, `"ferry"`, `"unpaved"`, `"motorway"`, `"trunk"`, `"primary"`, `"secondary"`, `"tertiary"`; a list or a comma-separated string (optional) |

```plazaql
route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), depart_at: "2026-03-16T08:00:00Z", traffic_model: "pessimistic", exclude: ["toll", "ferry"])
```

#### Truck options

With `mode: "truck"`, `route()`, `isochrone()` and `matrix()` take the vehicle as keywords (Plaza's REST `truck` object). The router skips roads whose OSM `maxheight`, `maxwidth`, `maxlength`, `maxweight` or `maxaxleload` is below the vehicle's, keeps to roads trucks may use, follows one-way streets and times the trip at truck speeds. Any option left out takes its default, a standard US semi-trailer. Plaza rejects values out of range.

| Parameter    | Type    | Description                                                                   |
|--------------|---------|-------------------------------------------------------------------------------|
| `height`     | number  | Metres, default 4.11, at most 10                                              |
| `width`      | number  | Metres, default 2.6, at most 10                                               |
| `length`     | number  | Metres, default 21.64, at most 60                                             |
| `weight`     | number  | Gross weight in tonnes, default 21.77, at most 200                            |
| `axle_load`  | number  | Heaviest axle in tonnes, at most 50 (optional)                                |
| `axle_count` | integer | 2 to 20; without `axle_load`, `weight / axle_count` is checked (optional)     |
| `hazmat`     | boolean | Hazardous load: avoids `hazmat=no` / `hazmat:water=no` roads and ADR tunnel categories B to E (default `false`) |

```plazaql
route(origin: point(40.71, -74.00), destination: point(40.76, -73.99), mode: "truck", height: 4.0, weight: 30, hazmat: true)
```

The options need `mode: "truck"` and are only accepted by these three functions. A truck route's properties include `mode`, the `truck` it was planned for and `warnings` about restrictions it exceeds on roads next to the route.

### `isochrone(center:, time:, mode:)`

Compute a travel-time polygon.

```plazaql
isochrone(center: point(40.71, -74.00), time: 900, mode: "foot")
```

| Parameter | Type    | Description                    |
|-----------|---------|--------------------------------|
| `center`  | Point   | Origin point                   |
| `time`    | integer or integer[] | Travel time in seconds; a list returns one polygon per time |
| `mode`    | string  | `"auto"`, `"foot"`, `"bicycle"`, `"truck"` (with the [truck options](#truck-options)) |
| `denoise` | number  | Contour denoising level, 0 to 100; applies when `time` is a list (optional) |
| `generalize` | number | Contour generalization tolerance in meters, 0 to 1000; applies when `time` is a list (optional) |

### `geocode(address)` / `geocode(address:, locality:, ...)`

Forward geocode — address string to point features.

```plazaql
geocode("1600 Pennsylvania Avenue, Washington DC")
```

Pass pre-parsed components as keywords instead of a string for structured geocoding (REST: `POST /api/v1/geocode/structured`). Structured input skips address parsing, so results are deterministic and rank by how many components they match:

```plazaql
geocode(address: "1600 Pennsylvania Ave", locality: "Washington", region: "DC", postalcode: "20500", country: "US")
```

| Parameter       | Type                  | Description                                                              |
|-----------------|-----------------------|--------------------------------------------------------------------------|
| `address`       | string                | House number and street (`"1600 Pennsylvania Ave"`, `"Rue de Rivoli 99"`) |
| `neighbourhood` | string                | Neighbourhood or suburb                                                  |
| `locality`      | string                | City, town or village                                                    |
| `county`        | string                | County or district                                                       |
| `region`        | string                | State, province or region                                                |
| `postalcode`    | string                | Postal or ZIP code                                                       |
| `country`       | string                | ISO 3166-1 alpha-2 code (`"US"`) or country name                         |
| `focus`         | Point                 | Bias results toward this point                                           |
| `country_code`  | string                | Restrict results to one country                                          |
| `bbox`          | Polygon               | Restrict results to `bbox(south, west, north, east)`                     |
| `layers`        | string or string list | Only these layers (below)                                                |
| `boundary_gid`  | string                | Only results inside this way or relation polygon (`"osm:relation:62422"`) |
| `limit`         | number                | Maximum results                                                          |

A structured call needs at least one of `address`, `locality`, `region` or `postalcode`.

`layers` takes `"address"` (addresses, streets and postal codes), `"poi"`, `"admin"` (neighbourhood up to country), or single layers: `"street"`, `"postalcode"`, `"neighbourhood"`, `"locality"`, `"county"`, `"region"`, `"country"`. `layer:` takes one of them, like the REST `layer` parameter. `autocomplete()` takes `layers`, `layer` and `boundary_gid` too.

`lang: "de"` localizes result names, like REST `?lang=`; without it the request's `Accept-Language` applies. `geocode()`, `autocomplete()` and `reverse_geocode()` all take it.

`geocode(addresses: ["...", "..."])` geocodes up to 1000 addresses at once and returns the `POST /api/v1/geocode/batch` body: `{"results": [FeatureCollection, ...], "count": n}`, in input order.

Every result carries `gid` (`"osm:node:123"`), `layer`, `confidence` (0 to 1), `match_type` (`"exact"`, `"interpolated"`, `"fuzzy"`, `"fallback"`), `accuracy` (`"point"` or `"centroid"`) and categories (`category`, `subcategory`, `categories`). When nothing matches the address, the street, postal code, then the admin areas named in the query are tried in turn, and those results come back with `match_type: "fallback"` and confidence at most 0.5.

```plazaql
// Cafes, but only inside Berlin's boundary
geocode("Cafe Einstein", layers: "poi", boundary_gid: "osm:relation:62422")
```

### `place_lookup(gid, ...)`

Look up places by Plaza GID, the `gid` of any geocoding result (REST: `GET /api/v1/place?ids=...`). Takes up to 50 GIDs, positional or as `ids: [...]`, and returns them in order with their admin hierarchy and categories:

```plazaql
place_lookup("osm:node:21154906", "osm:relation:62422")
```

GIDs are `osm:{node|way|relation}:{osm_id}`, or `osm:address:{id}` / `osm:place:{id}` for Plaza's address and place rows.

### `reverse_geocode(point, include:?)`

Reverse geocode — coordinates to address.

```plazaql
reverse_geocode(point(38.8977, -77.0365))
```

| Parameter | Type                  | Description                                   |
|-----------|-----------------------|-----------------------------------------------|
| `point`   | Point                 | Coordinates to reverse geocode                |
| `include` | string or string list | Extra data to attach: `"census"` (optional)   |
| `layer`   | string                | Only results of this layer (optional)         |
| `lang`    | string                | Language for result names (optional)          |

`include: "census"` (or `include: ["census"]`) attaches the US Census geographies that contain the point:

```plazaql
reverse_geocode(point(40.7484, -73.9856), include: "census")
```

The result gains a `census` object with GEOIDs and names for the state, county, tract, block group, ZCTA, place, CBSA, and congressional district. A field is `null` when the point isn't covered by that geography (outside the US, or not in any CBSA, for example). The shape, with illustrative values:

```json
"census": {
  "geoid_state": "36",
  "geoid_county": "36061",
  "geoid_tract": "36061007600",
  "geoid_block_group": "360610076001",
  "zcta": "10118",
  "place_geoid": "3651000",
  "cbsa_geoid": "35620",
  "cd_geoid": "3612",
  "names": {
    "state": "New York",
    "county": "New York County",
    "tract": "Census Tract 76",
    "block_group": "Block Group 1",
    "zcta": "10118",
    "place": "New York city",
    "cbsa": "New York-Newark-Jersey City, NY-NJ",
    "cd": "Congressional District 12"
  }
}
```

Any other `include:` value is a type error.

### `autocomplete(text)`

Autocomplete partial place names.

```plazaql
autocomplete("Eiffel Tow")
```

### `nearest(point:, radius:?)`

Find the nearest features to a point.

```plazaql
nearest(point: point(40.71, -74.00))
```

| Parameter | Type    | Description                    |
|-----------|---------|--------------------------------|
| `point`   | Point   | Reference point                |
| `radius`  | number  | Search radius in meters (optional) |

### `matrix(origins:, destinations:, mode:?)`

Compute a distance/duration matrix between sets of points.

```plazaql
matrix(origins: [point(40.71, -74.00), point(40.73, -73.99)], destinations: [point(40.75, -73.98)])
```

| Parameter      | Type     | Description                    |
|----------------|----------|--------------------------------|
| `origins`      | Point[]  | Origin points                  |
| `destinations` | Point[]  | Destination points             |
| `mode`         | string   | `"auto"`, `"foot"`, `"bicycle"`, `"truck"` (with the [truck options](#truck-options); optional) |
| `annotations`  | string or string[] | `"duration"` (always) and `"distance"` (optional) |
| `fallback_speed` | number | km/h used to estimate pairs with no route, which are otherwise null (optional) |

The two lists can be positional: `matrix([point(40.71, -74.00)], [point(40.75, -73.98)])`.

### `map_match(points:, mode:)`

Snap a GPS trace to the road network.

```plazaql
map_match(points: [point(40.71, -74.00), point(40.72, -73.99)], mode: "auto")
```

A `linestring(...)` works as the trace too: `map_match(linestring(point(40.71, -74.00), point(40.72, -73.99)))`.

| Parameter | Type    | Description                                |
|-----------|---------|--------------------------------------------|
| `points`  | Point[] | GPS trace, two or more points in order     |
| `mode`    | string  | `"auto"`, `"foot"`, `"bicycle"` (optional) |
| `radiuses` | number[] | Search radius in meters per point, default 50 (optional) |

### `optimize(points..., mode:)`

Solve the traveling salesman problem — optimal visit order.

```plazaql
optimize(point(40.71, -74.00), point(40.73, -73.99), point(40.75, -73.98), mode: "auto")
```

The positional points are the waypoints; `waypoints: [...]` is the keyword form.

| Parameter   | Type    | Description                                     |
|-------------|---------|-------------------------------------------------|
| `waypoints` | Point[] | Points to visit, 2 to 50 (or pass them positionally) |
| `mode`      | string  | `"auto"`, `"foot"`, `"bicycle"` (optional)      |
| `roundtrip` | boolean | Return to the first point (optional)            |

### `ev_route(origin:, destination:, battery:)`

EV-aware routing with charge stop planning.

```plazaql
ev_route(origin: point(40.71, -74.00), destination: point(42.36, -71.06), battery: 60000)
```

| Parameter            | Type    | Description                              |
|----------------------|---------|------------------------------------------|
| `origin`             | Point   | Start point                              |
| `destination`        | Point   | End point                                |
| `battery`            | number  | Battery capacity in watt-hours (required) |
| `initial_charge_pct` | number  | Initial charge percentage (optional)     |
| `min_charge_pct`     | number  | Minimum charge percentage (optional)     |
| `depart_at`, `traffic_model`, `exclude` | | Same as `route()` (optional) |

### `centroid(locations:, mode:?, metric:?, exclude:?)`

Find the meeting point: the spot on the road network with the least total
travel cost from every location. Each location travels to the meeting point,
so one-way streets count in that direction. The result is a point, so it works
as a geometry.

```plazaql
$meet = centroid(
  locations: [point(48.858, 2.294), point(48.870, 2.350), point(48.845, 2.340)],
  mode: "foot"
);
search(node, amenity: "cafe").around(300, $meet).limit(5);
```

| Parameter   | Type     | Description                                          |
|-------------|----------|------------------------------------------------------|
| `locations` | Point[]  | 2 to 50 starting points (required)                   |
| `mode`      | string   | `"auto"`, `"foot"`, `"bicycle"` (optional)           |
| `metric`    | string   | `"time"` (default) or `"distance"`: the total to minimise |
| `exclude`   | string[] | Road types to avoid, same as `route()` (optional)    |

The locations must lie within 2° of each other, and no one's trip may exceed
2 hours (150 km with `metric: "distance"`). Same as REST `POST /api/v1/centroid`.

### `expansion(action:, ...)`

Routing debug: every road edge the router settled while answering a route,
isochrone or matrix request, one LineString per edge. Edges on the computed
path have `on_path: true`. Pass the expanded computation's own keywords.

```plazaql
expansion(
  action: "route",
  origin: point(48.858, 2.294),
  destination: point(48.870, 2.350),
  expansion_properties: ["duration", "cumulative_cost"]
);
```

| Parameter              | Type     | Description                                         |
|------------------------|----------|-----------------------------------------------------|
| `action`               | string   | `"route"`, `"isochrone"` or `"matrix"` (required)   |
| `origin`, `destination`| Point    | Route endpoints (`route`)                           |
| `center`, `time`       | Point, number or number[] | Isochrone center and budget(s) in seconds (`isochrone`) |
| `origins`, `destinations` | Point[] | Matrix points, at most 100 pairs (`matrix`)        |
| `mode`                 | string   | `"auto"`, `"foot"`, `"bicycle"` (optional)          |
| `exclude`              | string[] | Road types to avoid (`route`, `matrix`; optional)   |
| `expansion_properties` | string[] | Per-edge properties: `"duration"` (default), `"distance"`, `"cost"`, `"cumulative_cost"`, `"edge_id"`, `"osm_way_id"` |

Same as REST `POST /api/v1/expansion`, including its access rule: the server
runs it only with the `X-Plaza-Debug: true` header or an admin API key.

### `elevation(point)`

Look up elevation at a single point.

```plazaql
elevation(point(27.9881, 86.9250))
```

Pass several points, positionally or as `points:`, to look them up at once:

```plazaql
elevation(points: [point(27.9881, 86.9250), point(28.5983, 83.9311)])
```

| Parameter | Type    | Description                               |
|-----------|---------|-------------------------------------------|
| `points`  | Point[] | Points to look up (instead of one point)  |

### `elevation_profile(linestring)`

Get elevation profile along a linestring.

```plazaql
elevation_profile(linestring(point(46.5, 6.6), point(46.0, 7.6)))
```

### `dataset(slug)`

Reference a named dataset as a search source.

```plazaql
search(dataset("my_data"), name: *)
```

Plaza also publishes curated datasets, such as the US Census geographies `dataset("census-counties")` and `dataset("census-tracts")`. Their attributes are feature properties, so you read them with `t["key"]` like any tag:

```plazaql
search(dataset("census-counties"))
  .filter(t["state_abbr"] == "NY")
  .sum(number(t["population"]));
```

---

## Geometry Constructors

### `point(lat, lng)` / `point(lat:, lng:)`

```plazaql
point(40.7128, -74.0060)
point(lat: 40.7128, lng: -74.0060)
```

Note: PlazaQL uses `lat, lng` order (human convention). Internally converted to GeoJSON `[lng, lat]`.

### `linestring(p1, p2, ...)`

```plazaql
linestring(point(40.71, -74.00), point(40.73, -73.99), point(40.75, -73.98))
```

Minimum 2 points.

### `polygon(p1, p2, p3, ...)`

```plazaql
polygon(point(40.71, -74.01), point(40.71, -73.99), point(40.73, -73.99), point(40.73, -74.01))
```

Minimum 3 points. Automatically closed (first point repeated).

### `bbox(south, west, north, east)`

Shorthand for a rectangular polygon from bounding box coordinates.

```plazaql
bbox(40.70, -74.02, 40.75, -73.97)
```

### `circle(center, radius)`

```plazaql
circle(point(40.71, -74.00), 500)  // 500 meter radius
```

---

## Methods

Methods are chained onto expressions with `.method()` syntax. They are organized into phases (see [Chain Ordering](#chain-ordering)).

### Spatial Filters (Phase 3)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.within(geom)` | `GeoSet → GeoSet` | Features inside a geometry (`Boundary`, `Isochrone`, `Polygon`, or `PolygonSet` only) |
| `.around(distance, geom)` | `GeoSet → GeoSet` | Features within distance (meters) of a geometry |
| `.bbox(s, w, n, e)` | `GeoSet → GeoSet` | Features in bounding box |
| `.h3(cell)` | `GeoSet → GeoSet` | Features in H3 cell |
| `.intersects(geom)` | `GeoSet → GeoSet` | Features that intersect a geometry |
| `.contains(geom)` | `GeoSet → GeoSet` | Features that fully contain a geometry |
| `.crosses(geom)` | `GeoSet → GeoSet` | Features that cross a geometry |
| `.touches(geom)` | `GeoSet → GeoSet` | Features that touch a geometry |
| `.not_within(geom)` | `GeoSet → GeoSet` | Features NOT inside a geometry (`Boundary`, `Isochrone`, `Polygon`, or `PolygonSet` only) |
| `.not_intersects(geom)` | `GeoSet → GeoSet` | Features NOT intersecting a geometry |
| `.not_contains(geom)` | `GeoSet → GeoSet` | Features NOT containing a geometry |
| `.member_of(source, role?)` | `GeoSet → GeoSet` | Features that are members of the source set |
| `.has_member(source, role?)` | `GeoSet → GeoSet` | Features that contain source elements as members |

```plazaql
search(node, amenity: "cafe")
  .within(boundary(name: "Manhattan"))
  .around(200, point(40.74, -73.98));
```

The geometry argument of `.within()`, `.intersects()`, `.contains()`, `.crosses()`, `.touches()`, and their `not_` forms can be a constructor (`point(...)`, `linestring(...)`, `polygon(...)`, `bbox(...)`) or a variable holding geometry, either `$var` or `$$.name`. The executor resolves the variable's geometry when the query runs: The argument can be positional or `geometry:`. An inline `boundary(...)`, computation (`isochrone(...)`, `route(...)`) or `search(...)` runs first, exactly as if it were assigned to a variable: `.within(boundary(name: "Manhattan"))` is `$m = boundary(name: "Manhattan"); ... .within($m)`.

```plazaql
$walk = isochrone(center: point(40.7484, -73.9856), time: 900, mode: "foot");
search(dataset("census-tracts")).intersects($walk);
```

`.within()` and `.not_within()` keep their type rule with variables: the variable must hold a `Boundary`, `Isochrone`, `Polygon` or `PolygonSet`. For a variable holding a general feature set (for example a `dataset(...)` search), use `.intersects($var)`.

### Tag Filter (Phase 3b)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.filter(tag_filters...)` | `GeoSet → GeoSet` | Apply tag filters post-search or post-union |

```plazaql
$combined = search(node, amenity: "cafe") + search(node, amenity: "restaurant");
$combined.filter(wheelchair: "yes", outdoor_seating: "yes");
```

### Transforms (Phase 4)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.buffer(meters)` | `GeoSet → PolygonSet` | Expand geometries by distance |
| `.simplify(meters)` | `GeoSet → GeoSet` | Reduce geometry complexity |
| `.centroid()` | `GeoSet → PointSet` | Convert to center points |

```plazaql
search(way, leisure: "park").buffer(100);    // 100m buffer around parks
search(way, boundary: *).simplify(1000);     // simplify to 1km tolerance
search(way, building: "yes").centroid();      // building center points
```

### Computed Columns (Phase 5)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.elevation()` | `GeoSet → GeoSet` | Add elevation data to features |
| `.distance(point)` | `GeoSet → GeoSet` | Add distance from reference point |
| `.area()` | `GeoSet → GeoSet` | Compute area of polygon features |
| `.length()` | `GeoSet → GeoSet` | Compute length of linear features |
| `.overlap_fraction(geom)` | `GeoSet → GeoSet` | Add `overlap_fraction`: the share (0 to 1) of each feature's area inside `geom` |

```plazaql
search(node, natural: "peak").elevation().sort(elevation());
search(node, amenity: "hospital").distance(point(40.71, -74.00)).sort(distance(point(40.71, -74.00)));
```

`.overlap_fraction(geom)` takes a `polygon(...)`, a `bbox(...)`, or a variable (`$var` / `$$.name`) holding polygons, like an isochrone or a boundary. Each result gets an `overlap_fraction` property:

```plazaql
$walk = isochrone(center: point(40.7484, -73.9856), time: 900, mode: "foot");
search(dataset("census-tracts")).intersects($walk).overlap_fraction($walk);
```

### Output Shape (Phase 6)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.fields(f1, f2, ...)` | `GeoSet → GeoSet` | Select specific tag fields |
| `.include(what, ...)` | `GeoSet → GeoSet` | Add computed fields: `"bbox"` (a GeoJSON `bbox` on each feature), `"center"` (`center_lat` and `center_lng` properties), `"distance"` (`distance_m`, when `.distance()` or `.around()` gives a reference point) |
| `.precision(n)` | `GeoSet → GeoSet` | Coordinate decimal places |
| `.geometry(false)` | `GeoSet → GeoSet` | Return properties only; each feature's `geometry` is `null` |

```plazaql
search(node, amenity: "cafe").fields("name", "cuisine", "opening_hours");
search(way, highway: "motorway").include("bbox", "center");
search(node, amenity: *).precision(4);
search(node, amenity: "cafe").geometry(false);
```

These match the REST `output.fields`, `output.include`, `output.precision` and `output.geometry` options. Any other `.include()` value is a compile error.

### Ordering (Phase 7)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.sort(expr, order?: :asc \| :desc)` | `GeoSet → GeoSet` | Sort by expression (`t["name"]`, `distance(point(...))`, `area()`, `length()`, `elevation()`) |
| `.limit(n)` | `GeoSet → GeoSet` | Maximum number of results |
| `.offset(n)` | `GeoSet → GeoSet` | Skip first n results |

```plazaql
search(node, amenity: "cafe").sort(t["name"]).limit(10).offset(20);
```

`.sort(by: :osm_id)` and `.sort(by: :name)` are the REST `output.sort=osm_id` and `output.sort=name`; see also `.sort(by: :qt)` below. Sorting by a string literal (`.sort("name")`) is a compile error, since it would sort every row by the same constant: write `.sort(t["name"])` or `.sort(by: :name)`.

### Output Mode (Phase 8) — Terminal

| Method | Signature | Description |
|--------|-----------|-------------|
| `.count()` | `GeoSet → Scalar` | Return count only |
| `.ids()` | `GeoSet → GeoSet` | Return only feature IDs |
| `.tags()` | `GeoSet → GeoSet` | Return only tags (no geometry) |
| `.skel()` | `GeoSet → GeoSet` | Minimal geometry, no tags |
| `.geom()` | `GeoSet → GeoSet` | Full geometry, no tags |

```plazaql
search(node, amenity: "cafe").within(boundary(name: "Paris")).count();
search(node, shop: *).ids();
search(way, building: "yes").within(boundary(name: "Manhattan")).geom();
```

Only one output mode per chain. These are terminal — no further chaining allowed.

### Quadtile Sort (Phase 7)

Sort results by quadtile index for optimal spatial locality — features near each other geographically appear near each other in the output:

```plazaql
search(node, amenity: "cafe")
  .within(boundary(name: "Berlin, Germany"))
  .sort(by: :qt)
  .limit(100);
```

The `:qt` atom is a special sort mode, not an expression. It's distinct from `.sort(t["name"])` which sorts by a tag value.

### Structural Joins (Phase 3)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.member_of(source, role?)` | `GeoSet → GeoSet` | Features that are members of the source set |
| `.has_member(source, role?)` | `GeoSet → GeoSet` | Features that contain the source elements as members |

Structural joins let you traverse OSM relationships — relations contain members (ways, nodes, other relations), and ways contain nodes. `.member_of()` finds elements that belong to a source, while `.has_member()` finds containers of a source.

```plazaql
// Bus stops on route 42
$route = search(relation, route: "bus", ref: "42");
search(node, highway: "bus_stop").member_of($route);

// With role filter
search(node, highway: "bus_stop").member_of($route, role: "stop");

// Reverse: find routes containing these stops
$stops = search(node, highway: "bus_stop").bbox(40.7, -74.0, 40.8, -73.9);
search(relation, route: "bus").has_member($stops);
```

### Narrowing (Phase 7b)

| Method | Signature | Description |
|--------|-----------|-------------|
| `.first()` | `GeoSet → GeoElement` | First element of the set |
| `.last()` | `GeoSet → GeoElement` | Last element of the set |
| `.index(n)` | `GeoSet → GeoElement` | Nth element (1-indexed) |

Narrowing methods reduce a set to a single element. Useful for picking a specific result to use in subsequent expressions.

```plazaql
// Nearest cafe
$nearest = search(node, amenity: "cafe")
  .around(1000, point(40.75, -73.99)).first();

// Third result
$third = search(node, amenity: "cafe")
  .around(1000, point(40.75, -73.99)).index(3);
```

### Attribute Access (`$var[attr]`)

Extract tag values from variables using bracket notation. The behavior depends on the source type:

- **GeoElement** (single element, e.g. from `.first()`): `$var[attr]` returns a scalar value, usable with `=` equality.
- **GeoSet** (multiple elements): `$var[attr]` returns a value set, matched with `ANY` semantics.

```plazaql
// Scalar: find stops with the same ref as the nearest stop
$stop = search(node, highway: "bus_stop")
  .around(500, point(40.75, -73.99)).first();
search(node, highway: "bus_stop", ref: $stop[ref]);

// Value set: find routes matching any ref from a set of stops
$stops = search(node, highway: "bus_stop").bbox(40.7, -74.0, 40.8, -73.9);
search(relation, route: "bus", ref: $stops[ref]);

// Output bracket ref: access tags on named outputs
$$.route = route(origin: point(40.71, -74.00), destination: point(40.75, -73.98));
$$.stops = search(node, highway: "bus_stop", ref: $$.route["ref"]);
```

### Recursion

| Method | Signature | Description |
|--------|-----------|-------------|
| `.expand(:down)` | `GeoSet → GeoSet` | Recurse into relation members / way nodes |
| `.expand(:up)` | `GeoSet → GeoSet` | Recurse up to parent relations |

```plazaql
search(relation, name: "Central Park").expand(:down);
```

---

## Tag Filters

Tag filters appear inside `search()` and `.filter()`.

### ID Filter

Look up specific OSM elements by ID:

```plazaql
search(node, id: 12345)           // single element
search(way, id: [123, 456, 789])  // multiple elements
```

ID filters bypass tag matching entirely — they fetch specific elements by their OSM ID.

### Key+Value Regex

Match tags whose **key** matches a regex pattern, using the `~"pattern"` prefix syntax on the key side:

```plazaql
search(node, ~"^addr:": ~"^[0-9]")   // addr:* tags with digit values
search(node, ~"^name:": *)            // any name:* translation tag
search(way, ~"^highway": "primary")   // keys matching ^highway with exact value
```

The key regex is a full POSIX regex. The value side supports all normal filter types (exact, regex, exists, etc.).

### Tag Value Filters

Nine filter types:

### Equals

```plazaql
amenity: "cafe"           // tags->>'amenity' = 'cafe'
```

### Not Equals

```plazaql
cuisine: !"fast_food"     // tags->>'cuisine' != 'fast_food'
```

### Regex

```plazaql
name: ~"^Starbucks"       // tags->>'name' ~ '^Starbucks'
```

### Case-Insensitive Regex

```plazaql
name: ~i"starbucks"       // tags->>'name' ~* 'starbucks'
```

### Negated Regex

```plazaql
name: !~"McDonald"        // NOT (tags->>'name' ~ 'McDonald')
```

### Exists

```plazaql
cuisine: *                // tags ? 'cuisine'
```

### Not Exists

```plazaql
name: !*                  // NOT tags ? 'name'
```

### Multiple Filters

Multiple filters in a single call are combined with AND:

```plazaql
search(node, amenity: "restaurant", cuisine: "italian", outdoor_seating: "yes")
// amenity=restaurant AND cuisine=italian AND outdoor_seating=yes
```

---

## Set Operations

### Union (`+`)

Combine two result sets:

```plazaql
$cafes = search(node, amenity: "cafe").within($area);
$restaurants = search(node, amenity: "restaurant").within($area);
$cafes + $restaurants;
```

### Difference (`-`)

Subtract one result set from another:

```plazaql
$all = search(node, amenity: ~"cafe|restaurant|fast_food").within($area);
$fast = search(node, amenity: "fast_food").within($area);
$all - $fast;
```

### Intersection (`&`)

Keep only features that appear in both sets:

```plazaql
$italian = search(node, cuisine: "italian").within($area);
$wheelchair = search(node, wheelchair: "yes").within($area);
$italian & $wheelchair;
```

Type rules for set operations:
- Same types preserve the type: `PointSet + PointSet → PointSet`
- Mixed types produce `GeoSet`: `PointSet + LineSet → GeoSet`
- Difference preserves the left operand's type
- Intersection: same types preserve the type; mixed types produce `GeoSet`

---

## Global Directives

Global directives apply a method to **all subsequent queries** in the program. They use `#method(args);` syntax — the same method names as chain methods, but prefixed with `#` and written as standalone statements.

```plazaql
#within(geometry: boundary(name: "Berlin"));
#filter(name: *);
#limit(count: 10);

// Every query below is scoped to Berlin, requires a name, and is capped at 10
$$.cafes = search(node, amenity: "cafe");
$$.parks = search(way, leisure: "park");
```

### Spatial Directives

```plazaql
#within(geometry: boundary(name: "Paris"));     // scope to boundary
#bbox(south: 47.0, west: 10.0, north: 48.0, east: 11.0);  // scope to bbox
#around(distance: 500, geometry: point(lat: 48.85, lng: 2.35));  // scope to radius
```

### Tag Filter Directive

```plazaql
#filter(name: *);                  // require name tag
#filter(wheelchair: "yes");        // require wheelchair access
```

### Expression Filter Directive

```plazaql
#filter(number(t["population"]) > 100000);   // only large cities
#filter(is_number(t["height"]));             // only features with numeric height
```

### Limit Directive

```plazaql
#limit(count: 5);    // cap all results to 5
```

### Stacking

Directives accumulate — each new one adds a constraint (AND semantics):

```plazaql
#within(geometry: boundary(name: "Tokyo"));
#filter(wheelchair: "yes");
#limit(count: 20);

// All queries below: in Tokyo, wheelchair-accessible, max 20 results
$$.cafes = search(node, amenity: "cafe");
$$.restaurants = search(node, amenity: "restaurant");
```

---

## Expression Language

PlazaQL includes an expression language for complex filtering and aggregation. Expressions appear inside `.filter()` and aggregation methods (`.sum()`, `.min()`, `.max()`, `.avg()`, `.group_by()`).

### Tag Access: `t["key"]`

Access tag values by key. Returns the string value of the tag, or null if the tag doesn't exist.

```plazaql
t["name"]            // → "Starbucks"
t["population"]      // → "3677000" (string — use number() for arithmetic)
t["cuisine"]         // → "italian"
```

`p["key"]` is the same accessor under another name, for reading dataset feature properties where "tag" reads oddly. The formatter writes it back as `t["key"]`.

```plazaql
search(dataset("census-tracts")).filter(number(p["population"]) > 5000);
```

### Property Accessors

Access feature metadata (not tags):

| Function | Returns | Description |
|----------|---------|-------------|
| `id()` | integer | OSM element ID |
| `type()` | string | Element type: `"node"`, `"way"`, `"relation"` |
| `lat()` | float | Latitude (nodes only) |
| `lon()` | float | Longitude (nodes only) |

```plazaql
search(node, amenity: "restaurant")
  .within(boundary(name: "Rome"))
  .filter(lat() < 41.89)
  .limit(10);
```

### Geometry Functions

Compute properties of each feature's geometry:

| Function | Returns | Description |
|----------|---------|-------------|
| `length()` | float | Geometry length in meters (lines/ways) |
| `area()` | float | Geometry area in square meters (polygons) |
| `elevation()` | float | Elevation in meters |
| `is_closed()` | boolean | Whether a linestring forms a closed ring |

```plazaql
// Long cycleways (> 5km)
search(way, highway: "cycleway")
  .filter(length() > 5000);

// Large parks
search(way, leisure: "park")
  .filter(area() > 100000);
```

**Important:** `length()` is always geometric (meters). For string character count, use `size()`.

### Overlap Fraction

`overlap_fraction(geom)` returns the share (0 to 1) of the feature's area that lies inside a reference polygon. It returns null for features with no area. `geom` must be a `polygon(...)`, a `bbox(s, w, n, e)`, or a variable holding polygons (`$var` or `$$.name`). Anything else is a type error.

Use it for area-weighted apportionment. If a census tract is 40% inside your area, it contributes 40% of its population:

```plazaql
search(dataset("census-tracts"))
  .intersects(polygon(point(40.70, -74.02), point(40.70, -73.97), point(40.75, -73.97), point(40.75, -74.02)))
  .sum(number(t["population"]) * overlap_fraction(polygon(point(40.70, -74.02), point(40.70, -73.97), point(40.75, -73.97), point(40.75, -74.02))));
```

With a variable:

```plazaql
$area = isochrone(center: point(40.7484, -73.9856), time: 900, mode: "foot");
search(dataset("census-tracts")).intersects($area).sum(number(t["population"]) * overlap_fraction($area));
```

It works anywhere an expression does: `.filter()`, `.sort()`, `.sum()`/`.min()`/`.max()`/`.avg()`, and `.group_by()`:

```plazaql
$area = isochrone(center: point(40.7484, -73.9856), time: 900, mode: "foot");
search(dataset("census-tracts"))
  .intersects($area)
  .filter(overlap_fraction($area) > 0.5)
  .sort(overlap_fraction($area), order: :desc);
```

To return the fraction as a property on each feature instead, use the [`.overlap_fraction(geom)`](#computed-columns-phase-5) method.

### Type Coercion

| Function | Description |
|----------|-------------|
| `number(expr)` | Convert string to number for arithmetic |
| `is_number(expr)` | Check if value can be parsed as a number |

```plazaql
// Guard + convert pattern
.filter(is_number(t["height"]) && number(t["height"]) > 50)
```

### String Functions

| Function | Description |
|----------|-------------|
| `starts_with(expr, str)` | String prefix check |
| `ends_with(expr, str)` | String suffix check |
| `str_contains(expr, str)` | Substring check |
| `size(expr)` | Character count |

```plazaql
.filter(starts_with(t["name"], "Via"))
.filter(size(t["name"]) > 50)
```

**Important:** `str_contains()` is for string containment. The spatial `.contains()` method is a separate chain method for geometry containment.

### Operators

| Operator | Type | Description |
|----------|------|-------------|
| `+`, `-`, `*`, `/` | Arithmetic | Numeric operations |
| `>`, `<`, `>=`, `<=` | Comparison | Numeric/string comparison |
| `==`, `!=` | Equality | Exact match / not match |
| `&&` | Logical AND | Both conditions true |
| `\|\|` | Logical OR | Either condition true |
| `!` | Logical NOT | Negate a condition |

```plazaql
// Compound: Italian OR Japanese restaurants
.filter(t["cuisine"] == "italian" || t["cuisine"] == "japanese")

// Arithmetic: multi-lane roads
.filter(is_number(t["lanes"]) && number(t["lanes"]) >= 4)

// Negation
.filter(!(t["opening_hours"] == ""))
```

### Expression Filter (`.filter(expr)`)

When `.filter()` receives an expression (rather than tag key-value pairs), it evaluates the expression for each feature:

```plazaql
// Tag filter syntax (key: value pairs)
.filter(amenity: "cafe", wheelchair: "yes")

// Expression filter syntax (full expression)
.filter(number(t["capacity"]) > 50 && t["wheelchair"] == "yes")
```

Both forms use `.filter()` — the parser distinguishes them automatically. Tag filters use `key: value` syntax; expression filters use operators and function calls.

---

## Aggregation

Aggregation methods reduce a result set to a single numeric value.

### Aggregation Methods (Phase 8) — Terminal

| Method | Signature | Description |
|--------|-----------|-------------|
| `.count()` | `GeoSet → Scalar` | Number of features |
| `.sum(expr)` | `GeoSet → Scalar` | Sum of expression values |
| `.min(expr)` | `GeoSet → Scalar` | Minimum expression value |
| `.max(expr)` | `GeoSet → Scalar` | Maximum expression value |
| `.avg(expr)` | `GeoSet → Scalar` | Average expression value |

The expression argument uses the same [expression language](#expression-language) — `t["key"]`, `number()`, `length()`, `area()`, etc.

```plazaql
// Total cycleway length in Amsterdam
search(way, highway: "cycleway")
  .within(boundary(name: "Amsterdam"))
  .sum(length());

// Tallest building in Dubai
search(way, building: "yes")
  .within(boundary(name: "Dubai"))
  .filter(is_number(t["height"]))
  .max(number(t["height"]));

// Average road segment length
search(way, highway: "residential")
  .within(boundary(name: "London"))
  .avg(length());
```

### Group By

`.group_by(expr)` partitions results by an expression value, then applies an aggregation to each group. Returns a map of `{group_key → aggregated_value}`.

```plazaql
// Count restaurants by cuisine
search(node, amenity: "restaurant", cuisine: *)
  .within(boundary(name: "Tokyo"))
  .group_by(t["cuisine"])
  .count();

// Total road length by highway type
search(way, highway: *)
  .within(boundary(name: "Berlin"))
  .group_by(t["highway"])
  .sum(length());

// Average building height by building type
search(way, building: *)
  .within(boundary(name: "Singapore"))
  .filter(is_number(t["height"]))
  .group_by(t["building"])
  .avg(number(t["height"]));
```

`.group_by()` must be followed by exactly one aggregation method (`.count()`, `.sum()`, `.min()`, `.max()`, `.avg()`). The result type is `GroupedSet` → `Scalar` after aggregation.

---

## Chain Ordering

Methods are organized into three ordering groups. Methods within the **freely orderable** group can appear in any order relative to each other. **Late chain** methods must come after all freely orderable methods. **Terminal** methods must be last, and only one is allowed per chain.

```
Source             search() | boundary() | route() | isochrone() | ...
Set ops            + | - | &

Freely orderable (any order among themselves):
  Spatial          .within() | .around() | .bbox() | .h3() |
                   .intersects() | .contains() | .crosses() | .touches() |
                   .not_within() | .not_intersects() | .not_contains() |
                   .member_of() | .has_member()
  Tag filter       .filter(key: value) | .filter(expression)
  Transforms       .buffer() | .simplify() | .centroid()
  Computed         .elevation() | .distance() | .area() | .length()
  Output shape     .fields() | .include() | .precision() | .expand()

Late chain (must come after freely orderable):
  Ordering         .sort() | .limit() | .offset()
  Narrowing        .first() | .last() | .index()
  Group by         .group_by(expr)

Terminal (must be last, only one allowed):
  Output mode      .count() | .ids() | .tags() | .skel() | .geom() |
                   .sum(expr) | .min(expr) | .max(expr) | .avg(expr)
```

**Valid:**
```plazaql
search(node, amenity: "cafe").within($area).sort(t["name"]).limit(10);
```

**Invalid** — `.limit()` (late chain) before `.within()` (freely orderable):
```plazaql
search(node, amenity: "cafe").limit(10).within($area);  // ERROR
```

---

## Argument Style

All functions and methods support **keyword** and **positional** arguments. You cannot mix styles in a single call.

```plazaql
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
   |               ^
   |
   = hint: add a comma: search(node, amenity: "cafe")
```

### Type Error

```
error: `.within()` requires an Area or Polygon variable
  --> query:5:3
   |
 5 |   .within(42)
   |           ^
   |
   = hint: use a geometry constructor: .within(boundary(name: "..."))
```

### Chain Order Error

```
error: `.limit()` (ordering) cannot follow `.within()` — ordering methods must come after spatial methods
  --> query:2:3
   |
 2 |   .limit(10)
   |   ^
   |
   = hint: move .limit(10) after .within($area)
```

### Undefined Variable

```
error: undefined variable $downtown
  --> query:4:12
   |
 4 |   .within($downtown)
   |            ^
   |
   = hint: assign it first: $downtown = boundary(name: "Downtown");
```

### Undefined Output Variable

```
error: undefined output variable $$.boundary
  --> query:3:12
   |
 3 |   .within($$.boundary)
   |            ^
   |
   = hint: assign it first: $$.boundary = boundary(name: "Berlin, Germany");
```

---

## Grammar

### EBNF

```ebnf
program        = (directive | statement)+ ;

directive      = "#" IDENT "(" (tag_filters | filter_expr | arg_list) ")" ";" ;

statement      = var_assign | out_assign | bare_expr ;
var_assign     = "$" IDENT "=" expression ";" ;
out_assign     = "$$" ("." IDENT)? "=" expression ";" ;
bare_expr      = expression ";" ;

expression     = set_expr ;
set_expr       = unary_expr (("+" | "-" | "&") unary_expr)* ;
unary_expr     = primary method_chain? ;

primary        = search | boundary_call | route_call | isochrone_call
               | geocode_call | reverse_geocode_call | autocomplete_call
               | place_lookup_call
               | matrix_call | map_match_call
               | optimize_call | ev_route_call | elevation_call
               | elevation_profile_call | nearest_call | centroid_call
               | expansion_call | dataset_call
               | constructor | variable | output_ref | output_named_ref
               | list_literal | "(" expression ")" ;

search         = "search" "(" search_args? ")" ;
search_args    = element_type ("," tag_filters)?
               | dataset_call ("," tag_filters)?
               | tag_filters | id_filter ;
id_filter      = "id" ":" (NUMBER | "[" NUMBER ("," NUMBER)* "]") ;
boundary_call  = "boundary" "(" tag_filters? ")" ;
route_call     = "route" "(" arg_list ")" ;
isochrone_call = "isochrone" "(" arg_list ")" ;
centroid_call  = "centroid" "(" arg_list ")" ;
expansion_call = "expansion" "(" arg_list ")" ;
geocode_call   = "geocode" "(" (STRING | arg_list) ")" ;
place_lookup_call = "place_lookup" "(" arg_list ")" ;
dataset_call   = "dataset" "(" STRING ")" ;
/* ... other function calls follow the same pattern */

constructor    = point | linestring | polygon | bbox | circle ;
point          = "point" "(" arg_list ")" ;
linestring     = "linestring" "(" arg_list ")" ;
polygon        = "polygon" "(" arg_list ")" ;
bbox           = "bbox" "(" NUMBER "," NUMBER "," NUMBER "," NUMBER ")" ;
circle         = "circle" "(" arg_list ")" ;

method_chain   = ("." method_call)+ ;
method_call    = IDENT ("(" (arg_list | filter_expr)? ")")? ;

arg_list       = keyword_args | positional_args ;
keyword_args   = keyword_arg ("," keyword_arg)* ;
keyword_arg    = IDENT ":" value ;
positional_args= value ("," value)* ;

tag_filters    = tag_filter ("," tag_filter)* ;
tag_filter     = (IDENT | regex_key) ":" tag_value ;
regex_key      = "~" STRING ;
tag_value      = STRING | "!" STRING | "~" STRING | "~i" STRING
               | "!~" STRING | "*" | "!*" | NUMBER | id_list ;
id_list        = "[" NUMBER ("," NUMBER)* "]" ;
list_literal   = "[" value ("," value)* "]" ;

/* Expression language (used in .filter(expr), .sum(expr), etc.) */
filter_expr    = or_expr ;
or_expr        = and_expr ("||" and_expr)* ;
and_expr       = equality ("&&" equality)* ;
equality       = comparison (("==" | "!=") comparison)? ;
comparison     = add_expr (("<" | ">" | "<=" | ">=") add_expr)? ;
add_expr       = mul_expr (("+" | "-") mul_expr)* ;
mul_expr       = unary (("*" | "/") unary)* ;
unary          = "!" unary | expr_primary ;
expr_primary   = tag_access | prop_access | geom_func | distance_func
               | overlap_func | coerce_func | string_func | size_func
               | constructor | variable | output_ref | attr_access
               | output_bracket_ref | atom
               | NUMBER | STRING | BOOL
               | "(" filter_expr ")" ;
tag_access     = "t" "[" STRING "]" ;
prop_access    = ("id" | "type" | "lat" | "lon") "(" ")" ;
geom_func      = ("length" | "area" | "elevation" | "is_closed") "(" ")" ;
distance_func  = "distance" "(" value ")" ;
overlap_func   = "overlap_fraction" "(" value ")" ;  /* polygon, bbox, $var, $$.name */
size_func      = "size" "(" filter_expr ")" ;
coerce_func    = ("number" | "is_number") "(" filter_expr ")" ;
string_func    = ("starts_with" | "ends_with" | "str_contains")
                 "(" filter_expr "," filter_expr ")" ;

element_type   = "node" | "way" | "relation" | "nwr" ;

value          = STRING | NUMBER | BOOL | constructor | variable
               | attr_access | output_ref | output_named_ref
               | output_bracket_ref | list_literal | atom
               | search | boundary_call | route_call | isochrone_call
               | dataset_call | "(" expression ")" ;
variable       = "$" IDENT ;
attr_access    = variable "[" (IDENT | STRING) "]" ;
output_ref     = "$$" ;
output_named_ref = "$$." IDENT ;
output_bracket_ref = "$$." IDENT "[" (IDENT | STRING) "]" ;
atom           = ":" IDENT ;

STRING         = '"' ( ~["\\\n] | '\\' . )* '"' ;
NUMBER         = "-"? [0-9]+ ("." [0-9]+)? ;
BOOL           = "true" | "false" ;
IDENT          = [a-zA-Z_] [a-zA-Z0-9_]* ;

LINE_COMMENT   = "//" ~[\n]* ;
BLOCK_COMMENT  = "/*" ( BLOCK_COMMENT | ~[*/] )* "*/" ;
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
