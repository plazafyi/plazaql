"use strict";
// PlazaQL type system — ported from Plaza.PlazaQL.Types
Object.defineProperty(exports, "__esModule", { value: true });
exports.FUNCTION_SIGNATURES = exports.COMMON_TAG_KEYS = exports.METHOD_CATALOG = exports.ALL_METHODS = void 0;
exports.isGeometric = isGeometric;
exports.isGeoSet = isGeoSet;
exports.isChainable = isChainable;
exports.isTerminal = isTerminal;
exports.unionType = unionType;
exports.methodPhase = methodPhase;
exports.isOutputMode = isOutputMode;
exports.isSpatialMethod = isSpatialMethod;
exports.methodOutputType = methodOutputType;
exports.validSpatialArgTypes = validSpatialArgTypes;
exports.computationType = computationType;
exports.searchBaseType = searchBaseType;
const GEOMETRY_TYPES = [
    "Point",
    "LineString",
    "Polygon",
    "Route",
    "Isochrone",
    "Area",
];
const GEO_SET_TYPES = [
    "PointSet",
    "LineSet",
    "PolygonSet",
    "GeoSet",
];
const CHAINABLE_TYPES = [
    ...GEO_SET_TYPES,
    "Route",
    "Isochrone",
    "Area",
];
const TERMINAL_TYPES = ["Matrix", "Elevation", "Scalar"];
function isGeometric(type) {
    return GEOMETRY_TYPES.includes(type);
}
function isGeoSet(type) {
    return GEO_SET_TYPES.includes(type);
}
function isChainable(type) {
    return CHAINABLE_TYPES.includes(type);
}
function isTerminal(type) {
    return TERMINAL_TYPES.includes(type);
}
function unionType(a, b) {
    if (a === b)
        return a;
    return "GeoSet";
}
const SPATIAL_METHODS = [
    "within",
    "not_within",
    "around",
    "near",
    "bbox",
    "h3",
    "intersects",
    "not_intersects",
    "contains",
    "not_contains",
    "crosses",
    "touches",
];
const TRANSFORM_METHODS = ["buffer", "simplify", "centroid"];
const ENRICHMENT_METHODS = ["elevation", "distance", "area", "length"];
const OUTPUT_SHAPE_METHODS = ["fields", "include", "precision", "expand"];
const ORDERING_METHODS = ["sort", "limit", "offset"];
const OUTPUT_MODE_METHODS = ["count", "ids", "tags", "skel"];
exports.ALL_METHODS = [
    ...SPATIAL_METHODS,
    "filter",
    ...TRANSFORM_METHODS,
    ...ENRICHMENT_METHODS,
    ...OUTPUT_SHAPE_METHODS,
    ...ORDERING_METHODS,
    ...OUTPUT_MODE_METHODS,
];
function methodPhase(method) {
    if (SPATIAL_METHODS.includes(method))
        return { ordinal: 3, label: "spatial (phase 3)" };
    if (method === "filter")
        return { ordinal: 3.5, label: "tag filter (phase 3b)" };
    if (TRANSFORM_METHODS.includes(method))
        return { ordinal: 4, label: "transform (phase 4)" };
    if (ENRICHMENT_METHODS.includes(method))
        return { ordinal: 5, label: "enrichment (phase 5)" };
    if (OUTPUT_SHAPE_METHODS.includes(method))
        return { ordinal: 6, label: "output shape (phase 6)" };
    if (ORDERING_METHODS.includes(method))
        return { ordinal: 7, label: "ordering (phase 7)" };
    if (OUTPUT_MODE_METHODS.includes(method))
        return { ordinal: 8, label: "output mode (phase 8)" };
    return { ordinal: 0, label: "unknown" };
}
function isOutputMode(method) {
    return OUTPUT_MODE_METHODS.includes(method);
}
function isSpatialMethod(method) {
    return SPATIAL_METHODS.includes(method);
}
function methodOutputType(method, inputType) {
    if (method === "centroid" && isChainable(inputType))
        return { ok: true, type: "PointSet" };
    if (method === "buffer" && isChainable(inputType))
        return { ok: true, type: "PolygonSet" };
    if (method === "count" && isChainable(inputType))
        return { ok: true, type: "Scalar" };
    if (method === "simplify" && inputType === "PointSet")
        return {
            ok: false,
            error: "`.simplify()` cannot be applied to PointSet",
        };
    if (isChainable(inputType)) {
        if (exports.ALL_METHODS.includes(method))
            return { ok: true, type: inputType };
        return { ok: false, error: `unknown method \`.${method}()\`` };
    }
    if (isTerminal(inputType))
        return {
            ok: false,
            error: `\`.${method}()\` cannot be applied to ${inputType} — ${inputType} is a terminal type that does not support chaining`,
        };
    return {
        ok: false,
        error: `\`.${method}()\` cannot be applied to ${inputType}`,
    };
}
const CONTAINMENT_TYPES = [
    "Area",
    "Isochrone",
    "Polygon",
    "PolygonSet",
];
function validSpatialArgTypes(method) {
    if (method === "within" || method === "not_within")
        return CONTAINMENT_TYPES;
    if (method === "crosses")
        return ["LineString", "Route", "LineSet"];
    return [...GEOMETRY_TYPES, ...GEO_SET_TYPES];
}
// ── Computation Type Inference ───────────────────────────────────────
const COMPUTATION_TYPES = {
    route: "Route",
    map_match: "Route",
    optimize: "Route",
    ev_route: "Route",
    isochrone: "Isochrone",
    geocode: "PointSet",
    reverse_geocode: "PointSet",
    autocomplete: "PointSet",
    text_search: "PointSet",
    nearest: "PointSet",
    matrix: "Matrix",
    elevation: "Elevation",
    elevation_profile: "Elevation",
};
function computationType(name) {
    return COMPUTATION_TYPES[name] ?? "GeoSet";
}
function searchBaseType(elemType) {
    if (elemType === "node")
        return "PointSet";
    return "GeoSet";
}
exports.METHOD_CATALOG = [
    // Spatial (phase 3)
    { name: "within", signature: ".within(geometry: Area | Polygon | Isochrone)", description: "Filter to features fully inside the geometry.", phase: "Spatial", ordinal: 3 },
    { name: "not_within", signature: ".not_within(geometry: Area | Polygon | Isochrone)", description: "Exclude features inside the geometry.", phase: "Spatial", ordinal: 3 },
    { name: "around", signature: ".around(distance: number, geometry?: Point | Area)", description: "Filter to features within distance (meters) of a point or geometry.", phase: "Spatial", ordinal: 3 },
    { name: "near", signature: ".near(geometry: Point, distance?: number)", description: "Alias for .around() with reversed argument order.", phase: "Spatial", ordinal: 3 },
    { name: "bbox", signature: ".bbox(s: number, w: number, n: number, e: number)", description: "Filter to features within a bounding box.", phase: "Spatial", ordinal: 3 },
    { name: "h3", signature: ".h3(cell: string)", description: "Filter to features within an H3 cell.", phase: "Spatial", ordinal: 3 },
    { name: "intersects", signature: ".intersects(geometry: Geometry)", description: "Filter to features that intersect the geometry.", phase: "Spatial", ordinal: 3 },
    { name: "not_intersects", signature: ".not_intersects(geometry: Geometry)", description: "Exclude features that intersect the geometry.", phase: "Spatial", ordinal: 3 },
    { name: "contains", signature: ".contains(geometry: Geometry)", description: "Filter to features that contain the geometry.", phase: "Spatial", ordinal: 3 },
    { name: "not_contains", signature: ".not_contains(geometry: Geometry)", description: "Exclude features that contain the geometry.", phase: "Spatial", ordinal: 3 },
    { name: "crosses", signature: ".crosses(geometry: LineString | Route)", description: "Filter to features that cross the geometry.", phase: "Spatial", ordinal: 3 },
    { name: "touches", signature: ".touches(geometry: Geometry)", description: "Filter to features that touch the geometry.", phase: "Spatial", ordinal: 3 },
    // Tag filter (phase 3b)
    { name: "filter", signature: ".filter(key: value, ...)", description: "Post-search/post-union tag filtering.", phase: "Tag Filter", ordinal: 3.5 },
    // Transform (phase 4)
    { name: "buffer", signature: ".buffer(meters: number)", description: "Expand geometries by a buffer distance.", phase: "Transform", ordinal: 4 },
    { name: "simplify", signature: ".simplify(tolerance: number)", description: "Simplify geometries (not valid on PointSet).", phase: "Transform", ordinal: 4 },
    { name: "centroid", signature: ".centroid()", description: "Replace geometries with their centroids. Result type becomes PointSet.", phase: "Transform", ordinal: 4 },
    // Enrichment (phase 5)
    { name: "elevation", signature: ".elevation()", description: "Add elevation data to features.", phase: "Enrichment", ordinal: 5 },
    { name: "distance", signature: ".distance(geometry: Point)", description: "Add distance from a reference point to each feature.", phase: "Enrichment", ordinal: 5 },
    { name: "area", signature: ".area()", description: "Add area calculation to polygon features.", phase: "Enrichment", ordinal: 5 },
    { name: "length", signature: ".length()", description: "Add length calculation to line features.", phase: "Enrichment", ordinal: 5 },
    // Output shape (phase 6)
    { name: "fields", signature: ".fields(field1, field2, ...)", description: "Select specific tag fields to include in output.", phase: "Output Shape", ordinal: 6 },
    { name: "include", signature: ".include(extra1, extra2, ...)", description: "Include additional data (e.g., geometry, metadata).", phase: "Output Shape", ordinal: 6 },
    { name: "precision", signature: ".precision(digits: number)", description: "Set coordinate precision for output.", phase: "Output Shape", ordinal: 6 },
    { name: "expand", signature: ".expand(direction: :down | :up)", description: "Expand relations to their members or ways to their nodes.", phase: "Output Shape", ordinal: 6 },
    // Ordering (phase 7)
    { name: "sort", signature: ".sort(by: field, order?: :asc | :desc)", description: "Sort results by a field. Use `distance` with prior `.around()`.", phase: "Ordering", ordinal: 7 },
    { name: "limit", signature: ".limit(n: number)", description: "Limit the number of results.", phase: "Ordering", ordinal: 7 },
    { name: "offset", signature: ".offset(n: number)", description: "Skip the first n results. Requires `.limit()` first.", phase: "Ordering", ordinal: 7 },
    // Output mode (phase 8)
    { name: "count", signature: ".count()", description: "Return only the count of matching features. Result type becomes Scalar.", phase: "Output Mode", ordinal: 8 },
    { name: "ids", signature: ".ids()", description: "Return only OSM IDs.", phase: "Output Mode", ordinal: 8 },
    { name: "tags", signature: ".tags()", description: "Return only tags (no geometry).", phase: "Output Mode", ordinal: 8 },
    { name: "skel", signature: ".skel()", description: "Return skeleton (IDs + minimal geometry).", phase: "Output Mode", ordinal: 8 },
];
// ── Common OSM Tag Keys (for completions) ────────────────────────────
exports.COMMON_TAG_KEYS = [
    "amenity",
    "name",
    "building",
    "highway",
    "shop",
    "tourism",
    "leisure",
    "natural",
    "landuse",
    "waterway",
    "railway",
    "aeroway",
    "boundary",
    "place",
    "addr:street",
    "addr:housenumber",
    "addr:city",
    "addr:postcode",
    "cuisine",
    "sport",
    "religion",
    "surface",
    "access",
    "wheelchair",
    "opening_hours",
    "phone",
    "website",
    "operator",
    "brand",
];
exports.FUNCTION_SIGNATURES = {
    search: {
        name: "search",
        params: [
            { name: "type", type: "node | way | relation | nwr", optional: true, description: "Element type to search" },
            { name: "...filters", type: "TagFilter", optional: true, description: "Tag key: value filters" },
        ],
        returnType: "GeoSet",
        description: "Search for OSM features matching tag filters.",
    },
    area: {
        name: "area",
        params: [
            { name: "...filters", type: "TagFilter", description: "Tag filters to identify the area (e.g., name: \"Berlin\")" },
        ],
        returnType: "Area",
        description: "Look up a named administrative boundary or area.",
    },
    point: {
        name: "point",
        params: [
            { name: "lat", type: "number", description: "Latitude" },
            { name: "lng", type: "number", description: "Longitude" },
        ],
        returnType: "Point",
        description: "Create a geographic point.",
    },
    bbox: {
        name: "bbox",
        params: [
            { name: "s", type: "number", description: "South latitude" },
            { name: "w", type: "number", description: "West longitude" },
            { name: "n", type: "number", description: "North latitude" },
            { name: "e", type: "number", description: "East longitude" },
        ],
        returnType: "Polygon",
        description: "Create a bounding box polygon.",
    },
    linestring: {
        name: "linestring",
        params: [
            { name: "...points", type: "Point", description: "Two or more points" },
        ],
        returnType: "LineString",
        description: "Create a line from a sequence of points.",
    },
    polygon: {
        name: "polygon",
        params: [
            { name: "...points", type: "Point", description: "Three or more points (auto-closed)" },
        ],
        returnType: "Polygon",
        description: "Create a polygon from a ring of points.",
    },
    route: {
        name: "route",
        params: [
            { name: "waypoints", type: "Point -> Point -> ...", description: "Route waypoints using arrow syntax" },
            { name: "mode", type: "\"auto\" | \"car\" | \"bicycle\" | \"foot\" | \"truck\"", optional: true, description: "Travel mode" },
        ],
        returnType: "Route",
        description: "Compute a route between waypoints.",
    },
    isochrone: {
        name: "isochrone",
        params: [
            { name: "center", type: "Point", description: "Center point" },
            { name: "time", type: "number", optional: true, description: "Travel time in seconds" },
            { name: "distance", type: "number", optional: true, description: "Travel distance in meters" },
            { name: "mode", type: "string", optional: true, description: "Travel mode" },
        ],
        returnType: "Isochrone",
        description: "Compute a travel-time or travel-distance polygon.",
    },
    geocode: {
        name: "geocode",
        params: [
            { name: "query", type: "string", description: "Address or place name to geocode" },
        ],
        returnType: "PointSet",
        description: "Geocode an address to coordinates.",
    },
    reverse_geocode: {
        name: "reverse_geocode",
        params: [
            { name: "point", type: "Point", description: "Coordinates to reverse geocode" },
        ],
        returnType: "PointSet",
        description: "Reverse geocode coordinates to an address.",
    },
    autocomplete: {
        name: "autocomplete",
        params: [
            { name: "query", type: "string", description: "Partial text to autocomplete" },
            { name: "center", type: "Point", optional: true, description: "Bias results toward this point" },
        ],
        returnType: "PointSet",
        description: "Autocomplete a place name or address.",
    },
    text_search: {
        name: "text_search",
        params: [
            { name: "query", type: "string", description: "Full-text search query" },
        ],
        returnType: "PointSet",
        description: "Full-text search for places.",
    },
    matrix: {
        name: "matrix",
        params: [
            { name: "sources", type: "Point[]", description: "Source points" },
            { name: "destinations", type: "Point[]", description: "Destination points" },
            { name: "mode", type: "string", optional: true, description: "Travel mode" },
        ],
        returnType: "Matrix",
        description: "Compute a distance/duration matrix between point sets.",
    },
    map_match: {
        name: "map_match",
        params: [
            { name: "points", type: "Point[]", description: "GPS trace points" },
            { name: "mode", type: "string", optional: true, description: "Travel mode" },
        ],
        returnType: "Route",
        description: "Snap a GPS trace to the road network.",
    },
    optimize: {
        name: "optimize",
        params: [
            { name: "waypoints", type: "Point[]", description: "Waypoints to optimize" },
            { name: "mode", type: "string", optional: true, description: "Travel mode" },
        ],
        returnType: "Route",
        description: "Optimize waypoint ordering (TSP).",
    },
    ev_route: {
        name: "ev_route",
        params: [
            { name: "waypoints", type: "Point -> Point", description: "Route waypoints" },
            { name: "battery", type: "number", optional: true, description: "Battery capacity" },
        ],
        returnType: "Route",
        description: "Compute an EV-optimized route with charging stops.",
    },
    elevation: {
        name: "elevation",
        params: [
            { name: "point", type: "Point", description: "Point to get elevation for" },
        ],
        returnType: "Elevation",
        description: "Get elevation at a point.",
    },
    elevation_profile: {
        name: "elevation_profile",
        params: [
            { name: "line", type: "LineString | Route", description: "Line to profile" },
        ],
        returnType: "Elevation",
        description: "Get elevation profile along a line.",
    },
    nearest: {
        name: "nearest",
        params: [
            { name: "point", type: "Point", description: "Reference point" },
            { name: "type", type: "string", optional: true, description: "Element type" },
        ],
        returnType: "PointSet",
        description: "Find nearest OSM features to a point.",
    },
};
//# sourceMappingURL=types.js.map