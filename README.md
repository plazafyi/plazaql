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
- [Using the Elixir library](#using-the-elixir-library)

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

A variable holding a literal (`point(...)`, `linestring(...)`, `polygon(...)`, `bbox(...)`, `circle(...)` or a number) is replaced by that literal wherever it is used, so `.around($radius, $center)` compiles exactly like `.around(500, point(40.7128, -74.0060))`. A literal is a value, not a query: `$center;` on its own is a compile error. A variable holding a search, boundary or computation runs once, before the statements that use it.

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

**Modes:** `"auto"`, `"foot"`, `"bicycle"`, `"truck"`, `"transit"`

| Parameter       | Type            | Description                                                                 |
|-----------------|-----------------|-----------------------------------------------------------------------------|
| `origin`        | Point           | Start point                                                                 |
| `destination`   | Point           | End point                                                                   |
| `mode`          | string          | `"auto"`, `"foot"`, `"bicycle"`, `"truck"`, `"motorcycle"`, `"motor_scooter"` (see [motorcycle and motor scooter options](#motorcycle-and-motor-scooter-options)), `"transit"` (with the [transit options](#transit-options)) (optional) |
| `waypoints`     | Point[]         | Points to visit in order (optional)                                         |
| `alternatives`  | number          | Number of alternative routes to return (optional)                           |
| `overview`      | string/false    | Route geometry detail: `"full"` (default), `"simplified"`, or `false` for none (optional) |
| `geometries`    | string          | Geometry encoding: `"geojson"` (default), `"polyline"`, `"polyline6"` (optional) |
| `annotations`   | boolean         | Per-edge duration and distance arrays (optional)                            |
| `depart_at`     | string          | ISO 8601 departure time or `"now"`, for time-of-day traffic (optional)      |
| `traffic_model` | string          | `"best_guess"` (default), `"optimistic"`, `"pessimistic"`; needs `depart_at` (optional) |
| `exclude`       | string[]/string | Road types to avoid: `"toll"`, `"cash_only_tolls"` (roads through a toll booth that takes only cash), `"ferry"`, `"unpaved"`, `"motorway"`, `"trunk"`, `"primary"`, `"secondary"`, `"tertiary"`; a list or a comma-separated string (optional). `isochrone()` and `matrix()` take it too |
| `steps`         | boolean         | Include turn-by-turn steps in `properties.steps` (optional, default `false`) |
| `lang`          | string          | BCP 47 language tag for step instructions (optional, default `"en"`); see below |
| `units`         | string          | `"km"` or `"mi"` for distances inside instructions (optional); defaults to `"mi"` when the `lang` region is US, GB, LR or MM, otherwise `"km"` |
| `verbal`        | boolean         | Add spoken variants `verbal_alert`, `verbal_pre`, `verbal_post`, `verbal_succinct` to each step (optional) |
| `voice_instructions` | boolean    | Add timed voice announcements (text and SSML) to each step, for the maneuver that ends it (optional; needs `steps`) |
| `banner_instructions` | boolean   | Add banner instructions (road, ref, signposted destinations, lanes) to each step (optional; needs `steps`) |
| `roundabout_exits` | boolean      | Give leaving a roundabout its own `exit_roundabout` step (optional; needs `steps`) |
| `voice_units`   | string          | `"metric"` or `"imperial"` for distances in voice announcements (optional, defaults to `units`) |
| `waypoint_names` | string[]/string | One name per point (origin, each waypoint, destination) for arrival instructions; `""` keeps the default; a list or a `;`-separated string (optional) |
| `avoid_datasets` | string[]/string | Datasets whose polygons the route stays out of (optional, below) |

```plazaql
route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), depart_at: "2026-03-16T08:00:00Z", traffic_model: "pessimistic", exclude: ["toll", "ferry"])
```

`avoid_datasets` takes up to 10 dataset slugs or ids, yours or Plaza-curated; `"plaza"` and `"all"` are not accepted. Every road segment that touches a polygon of those datasets is left out of the graph; point and line features are ignored. Plaza caps the datasets at 1,000 polygons and 200,000 vertices in total. `isochrone()`, `matrix()` and `ev_route()` take it too (REST: `avoid_datasets`).

```plazaql
route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), avoid_datasets: ["flood-zones"])
```

#### Truck options

With `mode: "truck"`, `route()`, `isochrone()`, `matrix()`, `optimize()`, `centroid()`, `expansion()` and `map_match()` take the vehicle as keywords (Plaza's REST `truck` object). The router skips roads whose OSM `maxheight`, `maxwidth`, `maxlength`, `maxweight` or `maxaxleload` is below the vehicle's, keeps to roads trucks may use, follows one-way streets and times the trip at truck speeds. Any option left out takes its default, a standard US semi-trailer. Plaza rejects values out of range.

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

The options need `mode: "truck"` and are only accepted by these functions. A truck route's properties include `mode`, the `truck` it was planned for and `warnings` about restrictions it exceeds on roads next to the route.

#### Bicycle and pedestrian options

With `mode: "bicycle"`, `route()`, `isochrone()`, `matrix()`, `optimize()`, `centroid()`, `expansion()` and `map_match()` take the rider's options as keywords (Plaza's REST `bicycle` object); with `mode: "foot"`, the walker's (REST `pedestrian` object). Options left out take their defaults. The bike type and the two speeds change travel times. The other options only change which way a route goes: they never add to its `duration_s`. `use_hills` belongs to whichever mode is set. Plaza rejects values out of range.

| Bicycle option       | Type   | Description                                                             |
|----------------------|--------|-------------------------------------------------------------------------|
| `bicycle_type`       | string | `"road"`, `"hybrid"` (default), `"cross"`, `"mountain"`: cruising speed, and how much rough surfaces slow the bike |
| `cycling_speed`      | number | Cruising speed in km/h, 5 to 50 (default: the type's)                   |
| `use_roads`          | number | 0 to 1, default 0.5. Lower values avoid busy roads without cycle lanes or tracks |
| `use_hills`          | number | 0 to 1, default 0.5. Lower values avoid climbs (needs elevation data)   |
| `avoid_bad_surfaces` | number | 0 to 1, default 0.25. Higher values avoid unpaved and rough ways        |

| Pedestrian option       | Type    | Description                                                         |
|-------------------------|---------|---------------------------------------------------------------------|
| `walking_speed`         | number  | km/h on flat ground, 1 to 10, default 5                             |
| `use_hills`             | number  | 0 to 1, default 0.5. Lower values avoid steep ways, up or down      |
| `use_lit`               | number  | 0 to 1, default 0. Higher values prefer lit ways                    |
| `walkway_factor`        | number  | Cost multiplier for footways and paths, 0.1 to 10, default 1        |
| `sidewalk_factor`       | number  | Cost multiplier for roads with a sidewalk, 0.1 to 10, default 1     |
| `step_penalty`          | number  | Seconds added per flight of steps, 0 to 3600, default 30            |
| `max_hiking_difficulty` | integer | Hardest SAC-scale trail, 1 (hiking) to 6, default 1                 |
| `wheelchair`            | boolean | No steps, no grades over 8%, smooth surfaces (default `false`)      |

```plazaql
route(origin: point(40.71, -74.00), destination: point(40.76, -73.99), mode: "bicycle", bicycle_type: "road", use_roads: 0.2)
route(origin: point(40.71, -74.00), destination: point(40.72, -73.99), mode: "foot", use_lit: 1, wheelchair: true)
```

The options need their mode and are only accepted by these functions.

#### Motorcycle and motor scooter options

`mode: "motorcycle"` (alias `"motorbike"`) and `mode: "motor_scooter"` (aliases `"scooter"`, `"moped"`) route on roads open to them: OSM `motorcycle=*` decides for motorcycles and `moped=*` for scooters, before `motor_vehicle`, `vehicle` and `access`. Both follow one-way streets like cars. Scooters never use motorways, or roads tagged `motorroad=yes` unless `moped` allows them, and ride at most 45 km/h unless `top_speed` says otherwise. `route()`, `isochrone()`, `matrix()`, `optimize()`, `centroid()`, `expansion()` and `map_match()` take the rider's options as keywords (Plaza's REST `motorcycle` and `motor_scooter` objects). Except `use_trails`, which decides whether tracks are ridden at all, they only change which way a route goes, not its `duration_s`. Plaza rejects values out of range.

| Motorcycle option | Type   | Description |
|-------------------|--------|-------------|
| `style`           | string | `"touring"` (default): direct, paved roads. `"adventure"`: curvy roads, unpaved surfaces and tracks are fine |
| `use_trails`      | number | 0 to 1. 0 keeps to roads; higher values ride tracks more willingly. Default 0 touring, 0.5 adventure |
| `use_curves`      | number | 0 (avoid) to 1 (seek) curvy roads, measured from each road's geometry; 0.5 is neutral. Default 0.5 touring, 0.8 adventure |

| Motor scooter option | Type   | Description |
|----------------------|--------|-------------|
| `use_primary`        | number | 0 to 1, default 0.2. Lower values avoid primary and trunk roads and roads with limits of 80 km/h or more |
| `use_hills`          | number | 0 to 1, default 0.5. Lower values avoid steep grades (needs elevation data) |

The [costing options](#costing-options) `use_highways`, `use_tolls`, `top_speed`, `fixed_speed`, `maneuver_penalty`, `service_penalty`, `gate_cost`, `toll_booth_cost` and `country_crossing_cost` apply to both modes. A scooter's `top_speed` replaces its 45 km/h default.

```plazaql
route(origin: point(46.55, 8.56), destination: point(46.63, 8.6), mode: "motorcycle", style: "adventure", use_curves: 1)
route(origin: point(41.89, 12.48), destination: point(41.91, 12.5), mode: "motor_scooter", use_primary: 0, top_speed: 50)
```

The options need their mode and are only accepted by these functions. A motorcycle or scooter route's properties include `mode`, the options it was planned with, `curviness_avg` and `surface_breakdown`.

#### Transit options

With `mode: "transit"`, `route()` and `isochrone()` plan walking plus public transit over the GTFS feeds Plaza has loaded (REST: `mode: "transit"` on `POST /route` and `POST /isochrone`). `depart_at` with an offset (`"...Z"`, `"...-04:00"`) is an instant; without one it is local time at the feed; `"now"` is the default.

| Parameter       | Type    | Description                                                                  |
|-----------------|---------|------------------------------------------------------------------------------|
| `use_bus`       | number  | 0 to 1, default 1. 0 never rides a bus; lower values count bus time more     |
| `use_rail`      | number  | 0 to 1, default 1. The same for tram, subway and rail                        |
| `use_transfers` | number  | 0 to 1, default 1. 0 allows no transfer; lower values add a penalty per transfer |
| `max_walk_m`    | number  | Longest walk in meters to the first stop, between stops and from the last stop; default 1000, at most 3000 |
| `max_transfers` | integer | Most changes between vehicles; default 3, at most 4                          |
| `arrive_by`     | string  | `route()` only. ISO 8601 arrival time, an instant with an offset or local time at the feed without one (not `"now"`): finds the latest departure that arrives by then. Not with `depart_at` |
| `wheelchair`    | boolean | Rides only trips marked wheelchair accessible and boards and alights only at stops marked wheelchair boarding (platforms inherit their station's value; unknown counts as not accessible); default `false` |

```plazaql
route(origin: point(42.3601, -71.0589), destination: point(42.3736, -71.1190), mode: "transit", depart_at: "2026-03-16T08:00:00-04:00", max_walk_m: 800)
isochrone(center: point(42.3601, -71.0589), time: [900, 1800], mode: "transit", depart_at: "2026-03-16T08:00:00")
route(origin: point(42.3601, -71.0589), destination: point(42.3736, -71.1190), mode: "transit", arrive_by: "2026-03-16T09:00:00-04:00", wheelchair: true)
```

The options need `mode: "transit"` and are only accepted by these two functions; `isochrone()` rejects `arrive_by`, and `depart_at` and `arrive_by` can't be combined. `wheelchair` also works with `mode: "foot"`, where it is the [pedestrian option](#bicycle-and-pedestrian-options). The [pedestrian options](#bicycle-and-pedestrian-options) (`walking_speed`, `use_hills`, `use_lit`, `walkway_factor`, `sidewalk_factor`, `step_penalty`, `max_hiking_difficulty`) apply to the walking legs: `walking_speed` sets their times, the others which ways are walked and which path is drawn; with `wheelchair: true` the walks are step-free too. Route options of the other modes (`waypoints`, `alternatives`, `exclude`, `steps`, the truck, bicycle, motorcycle and scooter options, ...) are refused with `mode: "transit"`. A transit route's properties list its `legs` (walks and vehicles with stops, route names and times), `depart_at`, `arrive_at` and `transfers`.

#### Costing options

`route()`, `ev_route()` and `matrix()` take the costing options of Plaza's REST routing endpoints; `isochrone()` takes `top_speed` and `fixed_speed` only, because its budget is travel time. Preferences and penalties change which route is chosen, not its `duration_s`. Plaza checks which modes take each option and rejects the rest.

| Parameter            | Type    | Description |
|----------------------|---------|-------------|
| `use_highways`       | number  | 0 to 1. Motorways and trunk roads: 0.5 (or leaving it out) is neutral, 0 avoids them (cost x10), 1 favours them (x0.9). `"auto"`, `"truck"`, `"motorcycle"`, `"motor_scooter"` |
| `use_tolls`          | number  | The same for toll roads. `"auto"`, `"truck"`, `"motorcycle"`, `"motor_scooter"` |
| `use_ferries`        | number  | The same for ferries (`route=ferry` ways, timed from their `duration` tag, else 20 km/h). Every mode |
| `use_living_streets` | number  | The same for living streets (x5 at 0). Every mode |
| `use_tracks`         | number  | The same for tracks (x15 at 0). `"foot"`, `"bicycle"` |
| `shortest`           | boolean | Minimise distance instead of time; not with the `use_*` or penalty options |
| `top_speed`          | integer | Highest speed driven, km/h (10-252). `"auto"`, `"truck"`, `"motorcycle"`, `"motor_scooter"` |
| `fixed_speed`        | integer | Drive every road at this speed, km/h (1-252), ignoring class, limits, surface, grade and traffic. `"auto"`, `"truck"`, `"motorcycle"`, `"motor_scooter"` |
| `maneuver_penalty`   | number  | Seconds (0-3600) added at each intersection the route arrives at. `"auto"`, `"truck"`, `"motorcycle"`, `"motor_scooter"` |
| `service_penalty`    | number  | Seconds (0-3600) added for each service road used. `"auto"`, `"truck"`, `"motorcycle"`, `"motor_scooter"` |
| `gate_cost`          | number  | Seconds (0-3600) added for each gate passed (`barrier=gate`, `lift_gate`, `swing_gate`, `sliding_gate`, `hampshire_gate` without `access=yes`, `permissive`, `designated` or `public`). Every mode |
| `toll_booth_cost`    | number  | Seconds (0-3600) added for each toll booth (`barrier=toll_booth`) passed. A booth already costs 15 s of travel time; this only steers the route. `"auto"`, `"truck"`, `"motorcycle"`, `"motor_scooter"` |
| `country_crossing_cost` | number | Seconds (0-3600) added for each country border crossed (a `barrier=border_control` node, or roads of two countries meeting). Every mode |

```plazaql
route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), use_tolls: 0, use_highways: 0.3, top_speed: 100)
matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], shortest: true)
```

#### Per-point options and recostings

`route()` takes one entry per point (origin, each waypoint, destination) for these, as a list or a `;`-separated string where an empty entry means "not set". PlazaQL has no `null`, so use the string form to leave a point out of `headings`.

| Parameter            | Type              | Description |
|----------------------|-------------------|-------------|
| `location_types`     | string[]/string   | `"break"` (a stop, the default; required at both ends), `"through"` (pass without stopping or turning back: no leg boundary, no arrival step) or `"via"` (like `"through"`, but may turn back) |
| `headings`           | number[]/string   | Direction of travel at the point, degrees from north. The point snaps to the nearest road it can be travelled along that way |
| `heading_tolerances` | number[]/string   | Largest difference from the heading accepted, degrees (default 60) |
| `preferred_sides`    | string[]/string   | `"same"` (the point on the driving side), `"opposite"` or `"either"` (default) |
| `approaches`         | string[]/string   | `"curb"` (reach the point on the driving side, the same as `preferred_sides` `"same"`) or `"unrestricted"` (default). A `"curb"` point can't have `preferred_sides` `"opposite"` |
| `recostings`         | string[]          | Price the route found under other costing models: `"name: key=value, ..."` with any costing option and an optional `mode=auto`, `foot`, `bicycle`, `motorcycle` or `motor_scooter` (at most 5) |

```plazaql
route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), waypoints: [point(40.73, -73.99)], location_types: ["break", "through", "break"], headings: "90;;", preferred_sides: ";;same", recostings: ["no_tolls: use_tolls=0", "walk: mode=foot"]);
```

The route reports each recosting under `properties.recostings.<name>` as `duration_s` and `cost`, both null when that mode cannot travel the path. REST takes the same recostings as objects (`{"name": "no_tolls", "use_tolls": 0}`) or as these strings.

Turn-by-turn steps in French, with spoken variants:

```plazaql
route(origin: point(48.8606, 2.3376), destination: point(48.8566, 2.3522), steps: true, lang: "fr", verbal: true)
```

Navigation output for a turn-by-turn app: voice and banner instructions on
every step, announcements in imperial units, and a named destination:

```plazaql
route(origin: point(40.71, -74.00), destination: point(40.75, -73.98), steps: true, voice_instructions: true, banner_instructions: true, voice_units: "imperial", waypoint_names: ["", "Office"])
```

With `steps`, each step also has its `geometry`, `intersections` (bearings,
entry flags, `lanes` from `turn:lanes`), `weight` and `mode`, and the route
has `legs` (summary, per-coordinate `annotations` with `annotations: true`)
and snapped `waypoints`, as POST /route returns them.

`lang` is the same parameter as POST /route's. The primary subtag picks the
language (`"pt-BR"` uses `"pt"`, `"zh-Hans"` uses `"zh"`) and the region sets
the default `units`. Supported: `ar` Arabic, `da` Danish, `de` German, `en`
English, `es` Spanish, `fi` Finnish, `fr` French, `hi` Hindi, `id`
Indonesian, `it` Italian, `ja` Japanese, `ko` Korean, `nb` Norwegian Bokmål
(`no` and `nn` map to it), `nl` Dutch, `pl` Polish, `pt` Portuguese, `ru`
Russian, `sv` Swedish, `th` Thai, `tr` Turkish, `vi` Vietnamese, `zh`
Chinese (Simplified). Any other language is a type error.

### `isochrone(center:, time:, mode:)`

Compute a travel-time polygon.

```plazaql
isochrone(center: point(40.71, -74.00), time: 900, mode: "foot")
```

| Parameter | Type    | Description                    |
|-----------|---------|--------------------------------|
| `center`  | Point   | Origin point                   |
| `time`    | integer or integer[] | Travel time in seconds; a list returns one polygon per time |
| `mode`    | string  | `"auto"`, `"foot"`, `"bicycle"`, `"truck"` (with the [truck options](#truck-options)), `"motorcycle"`, `"motor_scooter"`, `"transit"` (with the [transit options](#transit-options)) |
| `depart_at` | string | Departure time for `mode: "transit"`, as in `route()` (optional) |
| `top_speed`, `fixed_speed` | integer | The [speed overrides](#costing-options), as in `route()` (optional) |
| `denoise` | number  | Contour denoising level, 0 to 100; applies when `time` is a list (optional) |
| `generalize` | number | Contour generalization tolerance in meters, 0 to 1000; applies when `time` is a list (optional) |
| `exclude` | string[]/string | Road types to leave out, as in `route()` (optional; not with `mode: "transit"`) |
| `avoid_datasets` | string[]/string | Datasets whose polygons to stay out of, as in `route()` (optional) |

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
| `datasets`      | string or string list | Also match features of these datasets (below)                            |
| `dataset_name_field` | string           | Dataset property to match instead of the feature name (below)            |
| `limit`         | number                | Maximum results                                                          |

A structured call needs at least one of `address`, `locality`, `region` or `postalcode`.

`layers` takes `"address"` (addresses, streets and postal codes), `"poi"`, `"admin"` (neighbourhood up to country), `"dataset"` (matches from `datasets`), or single layers: `"street"`, `"postalcode"`, `"neighbourhood"`, `"locality"`, `"county"`, `"region"`, `"country"`. `layer:` takes one of them, like the REST `layer` parameter. `autocomplete()` takes `layers`, `layer`, `boundary_gid`, `datasets` and `dataset_name_field` too.

`lang: "de"` localizes result names, like REST `?lang=`; without it the request's `Accept-Language` applies. `geocode()`, `autocomplete()` and `reverse_geocode()` all take it.

`geocode(addresses: ["...", "..."])` geocodes up to 1000 addresses at once and returns the `POST /api/v1/geocode/batch` body: `{"results": [FeatureCollection, ...], "count": n}`, in input order.

`datasets` adds dataset features as candidates (REST: `datasets`). It takes dataset slugs or ids, `"plaza"` for every Plaza dataset, or `"all"` for those plus your own; another user's dataset is "dataset not found". The query text (for structured calls, the most specific component given) is matched against each feature's name, `properties.name`, or the property `dataset_name_field` names. Matches rank by text similarity alongside the OSM results, and carry `layer: "dataset"`, `dataset` (the slug), `dataset_id`, `feature_id` and the feature's properties as `dataset_properties`. `bbox`, `boundary_gid` and `country_code` filter them too.

```plazaql
geocode("Union Square", datasets: ["my-stores"], focus: point(37.788, -122.407))
```

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
| `datasets` | string or string list | Datasets to look up at the point (optional, below) |

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

`datasets: [...]` (slugs, ids, `"plaza"` or `"all"`) attaches a `datasets` list to the response and to every result: per dataset, each polygon that contains the point, smallest first (`"match": "contains"`) and the nearest point or line feature within `radius` (`"match": "nearest"`, with `distance_m`). Each entry has `dataset`, `dataset_id`, `id`, `name`, `feature_type`, `match`, `distance_m` and `properties`.

```plazaql
reverse_geocode(point(40.7484, -73.9856), datasets: ["census-tracts", "my-territories"])
```

### `autocomplete(text)`

Autocomplete partial place names.

```plazaql
autocomplete("Eiffel Tow")
```

It takes `layers`, `layer`, `boundary_gid`, `lang`, `datasets` and `dataset_name_field` like `geocode()`.

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
| `mode`         | string   | `"auto"`, `"foot"`, `"bicycle"`, `"truck"` (with the [truck options](#truck-options)), `"motorcycle"`, `"motor_scooter"` (optional) |
| `annotations`  | string or string[] | `"duration"` (always) and `"distance"` (optional) |
| `fallback_speed` | number | km/h used to estimate pairs with no route, which are otherwise null (optional) |
| `exclude`      | string[]/string | Road types to leave out, as in `route()` (optional) |
| `avoid_datasets` | string[]/string | Datasets whose polygons to stay out of, as in `route()` (optional) |
| the [costing options](#costing-options) | | As in `route()`; durations stay travel time (optional) |

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
| `mode`    | string  | Match only to roads this mode may use: `"auto"`, `"foot"`, `"bicycle"`, `"truck"`, `"motorcycle"`, `"motor_scooter"`, with that mode's options (optional; without it any road matches) |
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
| `mode`      | string  | `"auto"`, `"foot"`, `"bicycle"`, `"truck"`, `"motorcycle"`, `"motor_scooter"`, with that mode's options (optional) |
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
| `depart_at`, `traffic_model`, `exclude`, `avoid_datasets`, `steps`, `lang`, `units`, `verbal`, `voice_instructions`, `banner_instructions`, `roundabout_exits`, `voice_units`, `waypoint_names`, the [costing options](#costing-options) | | Same as `route()` (optional) |

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
| `mode`      | string   | `"auto"`, `"foot"`, `"bicycle"`, `"truck"`, `"motorcycle"`, `"motor_scooter"`, with that mode's options (optional) |
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
| `mode`                 | string   | `"auto"`, `"foot"`, `"bicycle"`, `"truck"`, `"motorcycle"`, `"motor_scooter"`, with that mode's options (optional) |
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

Spatial methods combine: every one in a chain applies, so `search(node, amenity: "cafe").around(500, $home).within($city)` keeps cafes that are both near `$home` and inside `$city`. Two `.around()` calls keep what is near both points. A `#within(...)` or `#bbox(...)` directive applies on top of the chain's own spatial methods. `.bbox()` also takes keywords: `.bbox(south: 40.7, west: -74.0, north: 40.8, east: -73.9)`.

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
| `.sort(expr, order?: :asc \| :desc)` | `GeoSet → GeoSet` | Sort by expression (`t["name"]`, `distance(point(...))`, `distance($var)`, `area()`, `length()`, `elevation()`) |
| `.limit(n)` | `GeoSet → GeoSet` | Maximum number of results |
| `.offset(n)` | `GeoSet → GeoSet` | Skip first n results |
| `.cursor(token)` | `GeoSet → GeoSet` | Continue after the previous page (keyset pagination) |

```plazaql
search(node, amenity: "cafe").sort(t["name"]).limit(10).offset(20);
```

#### Pagination with `.cursor()`

When a search with `.limit(n)` has more rows than `n`, the server returns
the page with a `next_cursor` string. Run the same query again with
`.cursor("<next_cursor>")` to get the next page. The last page has no
`next_cursor`.

```plazaql
// Page 1
search(node, amenity: "cafe").within(boundary(name: "Manhattan")).limit(100);

// Page 2: the same query, plus the cursor from page 1
search(node, amenity: "cafe")
  .within(boundary(name: "Manhattan"))
  .limit(100)
  .cursor("SFMyNTY.g2gDYQFtAAAAEH...");
```

- The token is opaque and signed by the server. Copy it as returned. A
  token from a different query, or one that was edited, is rejected with
  `invalid_cursor`.
- Changing `.limit()`, `.fields()` or `.precision()` between pages is fine.
  Changing a filter, the spatial area, the sort or the element types makes
  it a different query, so the old cursor no longer applies.
- `.cursor()` cannot be combined with `.offset()`. It takes exactly one
  string.
- Each output of a multi-output query pages on its own:
  `$$.cafes = search(...).limit(50).cursor("...");` gets its own
  `next_cursor`.
- Pages follow the query's sort. Without `.sort()`, rows come in element
  type order (as listed in `search(...)`), then by OSM id. A cursor holds
  the last row's sort value, so `.sort(distance(p))` pages continue at the
  right distance. `text_search(...)` pages follow its score.
- Plans that return one value or a combined set do not page: `.count()`,
  aggregates, `.group_by()`, set operations (`+`, `-`, `&`), `.first()`,
  `.last()`, `.index()` and `.tile()`. A cursor on them is an error.

The compiler keeps the token in `Plan.cursor` and SQL generation ignores
it. The server decodes it and resumes after that row.

`distance($var)` measures to a variable: a `point(...)` variable works like the literal, and a variable holding a search or computation measures to its geometry (rows are NULL, sorted last, when it is empty).

`.sort(by: :osm_id)` and `.sort(by: :name)` are the REST `output.sort=osm_id` and `output.sort=name`; see also `.sort(by: :qt)` below. Sorting by a string literal (`.sort("name")`) is a compile error, since it would sort every row by the same constant: write `.sort(t["name"])` or `.sort(by: :name)`.

### Output Mode (Phase 8) — Terminal

| Method | Signature | Description |
|--------|-----------|-------------|
| `.count()` | `GeoSet → Scalar` | Return count only |
| `.ids()` | `GeoSet → GeoSet` | Return only feature IDs |
| `.tags()` | `GeoSet → GeoSet` | Return only tags (no geometry) |
| `.skel()` | `GeoSet → GeoSet` | Minimal geometry, no tags |
| `.geom()` | `GeoSet → GeoSet` | Full geometry, no tags |
| `.tile(z, x, y, layers?:)` | `GeoSet → Scalar` | One Mapbox Vector Tile of the results (see below) |

```plazaql
search(node, amenity: "cafe").within(boundary(name: "Paris")).count();
search(node, shop: *).ids();
search(way, building: "yes").within(boundary(name: "Manhattan")).geom();
```

Only one output mode per chain. These are terminal — no further chaining allowed.

### Vector Tiles

`.tile(z, x, y)` renders the results as one Mapbox Vector Tile at slippy-map coordinates `z/x/y`, the same tile `GET /api/v1/tiles/{z}/{x}/{y}` returns for the same filters. The tile itself sets the area, so the chain takes no spatial methods. What carries over:

| PlazaQL | REST query parameter |
|---------|----------------------|
| `search(node, ...)`, `search(way, ...)`, `search(nwr, ...)` | `element_types=node,way` |
| `key: "value"` | `tags[key]=value` |
| `key: *` | `tags[key]=*` |
| `.fields("name", "cuisine")` | `properties=name,cuisine` |
| `layers: ["pois", "buildings"]` | `layers=pois,buildings` |

```plazaql
// Restaurants with a cuisine tag, as one tile over lower Manhattan
search(node, amenity: "restaurant", cuisine: *)
  .fields("name", "cuisine")
  .tile(14, 4823, 6160);
```

```plazaql
// Shortbread layers instead of the filtered `features` layer
search(nwr, building: *).tile(15, 9647, 12320, layers: ["buildings", "addresses"]);
```

Tag filters are limited to `key: "value"` and `key: *`, the two forms the REST endpoint takes. The server decides the zoom range it serves and the layer names it knows.

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

`p["key"]` is the same accessor under another name, for reading dataset feature properties where "tag" reads oddly. It works everywhere `t["key"]` does (`.filter()`, `.sort()`, `.group_by()`, the aggregates, `#filter()`) and compiles to the same SQL. The formatter writes it back as `t["key"]`.

```plazaql
search(dataset("census-tracts")).filter(number(p["population"]) > 5000);
search(dataset("census-counties")).group_by(p["state_abbr"]).sum(number(p["population"]));
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
  Ordering         .sort() | .limit() | .offset() | .cursor()
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

## Using the Elixir library

The `plazaql` Hex package compiles PlazaQL to parameterized PostGIS SQL. It
has no runtime dependencies besides the [tree-sitter CLI](https://tree-sitter.github.io/tree-sitter/creating-parsers/1-getting-started.html),
which parses the source. It never connects to a database: you run the SQL
with whatever driver you use.

```elixir
def deps do
  [{:plazaql, "~> 0.1"}]
end
```

### One query

`PlazaQL.query/2` takes a source string and returns one SQL statement and
its parameters:

```elixir
{:ok, %PlazaQL.Query{sql: sql, params: params}} =
  PlazaQL.query(~s|search(node, amenity: "cafe").bbox(38.8, -77.1, 39.0, -76.9);|)

{:ok, %Postgrex.Result{rows: rows}} = Postgrex.query(conn, sql, params)
```

The default schema matches the usual OpenStreetMap layout: `osm_nodes`,
`osm_ways` and `osm_relations` tables with `osm_id`, `tags` (jsonb) and `geom`
(SRID 4326) columns. Every value is a `$N` parameter. Table and column names
come from the schema, which only accepts plain lowercase identifiers.

A search over several element types (`nwr`) is a `UNION ALL` of one `SELECT`
per table, merged in sort order before the limit. Counts and aggregates over
several types are wrapped in an outer query that adds them up, with
averages weighted by row count. Set operations (`+`, `-`, `&`) become CTEs.

### Your own schema

```elixir
schema =
  PlazaQL.Schema.new(
    tables: [node: "points", way: "lines", relation: "areas"],
    columns: [id: "id", geometry: "geometry", tags: "tags"],
    srid: 4326
  )

{:ok, query} = PlazaQL.query(source, schema: schema)
```

Tags must be a `jsonb` column: filters use `?`, `->>` and `@>`.

### Extra conditions

`plan.custom_clauses` adds your own WHERE conditions, each with its own
`$1..$n` parameters (renumbered when spliced in). A three-element clause
applies to one element type or source only:

```elixir
{:ok, %{plans: [plan]}} = PlazaQL.compile(~s|search(node, amenity: "cafe");|)

plan = %{plan | custom_clauses: [{"updated_at > $1", [~U[2026-01-01 00:00:00Z]]}]}
{:ok, %PlazaQL.Query{sql: sql}} = PlazaQL.to_sql(plan)
```

Optional parts of the schema:

- `columns: [tile_id: "...", partition_tile_id: "..."]` with
  `extensions: [h3: true, partition_pruning: true]` enable H3 cell filters
  (`.h3(...)`, `sort: :qt`) and let you pass precomputed H3 cells and
  partition keys in `plan.caller_context` for index and partition pruning.
- `full_columns: [node: ["version", "changeset"]]` adds columns to full
  output.
- `admin_boundaries_table:` and `elevation_table:` back `is_in` filters and
  `elevation()`.
- `sources:` declares other tables of features (a geometry plus a jsonb
  column of properties) that plans can read next to the OSM element types.
  See `PlazaQL.Schema.Source`.

### Step by step

Each stage is a function, so you can stop anywhere:

```elixir
{:ok, ast} = PlazaQL.parse(source)
{:ok, checked} = PlazaQL.TypeChecker.check(ast)
{:ok, %{plans: plans, steps: steps}} = PlazaQL.Compiler.compile(checked)

{:ok, query} = PlazaQL.to_sql(hd(plans), schema)
```

`PlazaQL.compile/2` runs the first three stages at once.

A plan can need work only your application can do:

- **Computations** (`route`, `isochrone`, `geocode`, ...) compile to plans
  with `kind: :computation`. `to_sql/2` returns
  `{:error, %PlazaQL.NotCompilable{reason: :route}}` for them.
- **Variables.** In `$area = boundary(name: "Paris"); search(node).within($area);`
  the second statement references the first. Run the step it depends on,
  then replace the reference with the geometry you got back, for example
  `{:predicate, :within, {:ewkt, "SRID=4326;MULTIPOLYGON(...)"}}`.
  An unresolved reference returns `NotCompilable`.
- **Pagination.** Sorted rows come back with a `sort_key` column. Set
  `plan.seek` to `{sort_key, branch_rank, id}` of the last row you returned,
  and the next query starts after it.

### One query per branch

`PlazaQL.SQL.branches/2` returns one self-contained statement per element
type or source instead of a single `UNION ALL`. Use it when branches select
different columns, or when you run them separately and merge the rows
yourself. Every branch orders its rows by the sort and then by its key
columns, so rows from several branches merge on
`(sort_key, branch rank, keys)`.

```elixir
{:ok, %{plans: [plan]}} = PlazaQL.compile(~s|search(nwr, amenity: "cafe").limit(5);|)
{:ok, [node: node_query, way: way_query, relation: relation_query]} = PlazaQL.SQL.branches(plan)
```

[`docs/compiler.md`](./docs/compiler.md) describes the pipeline and the SQL
patterns in more detail.

## License

MIT — see [LICENSE](./LICENSE).
