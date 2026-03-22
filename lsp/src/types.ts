// PlazaQL type system — ported from Plaza.PlazaQL.Types

// ── PlazaQL Types ────────────────────────────────────────────────────

export type PqlType =
  | "Point"
  | "LineString"
  | "Polygon"
  | "PointSet"
  | "LineSet"
  | "PolygonSet"
  | "GeoSet"
  | "Route"
  | "Isochrone"
  | "Area"
  | "Matrix"
  | "Elevation"
  | "Scalar";

const GEOMETRY_TYPES: PqlType[] = [
  "Point",
  "LineString",
  "Polygon",
  "Route",
  "Isochrone",
  "Area",
];
const GEO_SET_TYPES: PqlType[] = [
  "PointSet",
  "LineSet",
  "PolygonSet",
  "GeoSet",
];
const CHAINABLE_TYPES: PqlType[] = [
  ...GEO_SET_TYPES,
  "Route",
  "Isochrone",
  "Area",
];
const TERMINAL_TYPES: PqlType[] = ["Matrix", "Elevation", "Scalar"];

export function isGeometric(type: PqlType): boolean {
  return GEOMETRY_TYPES.includes(type);
}

export function isGeoSet(type: PqlType): boolean {
  return GEO_SET_TYPES.includes(type);
}

export function isChainable(type: PqlType): boolean {
  return CHAINABLE_TYPES.includes(type);
}

export function isTerminal(type: PqlType): boolean {
  return TERMINAL_TYPES.includes(type);
}

export function unionType(a: PqlType, b: PqlType): PqlType {
  if (a === b) return a;
  return "GeoSet";
}

// ── Source Position ──────────────────────────────────────────────────

export interface Pos {
  line: number; // 1-based
  col: number; // 1-based
}

// ── AST Nodes ────────────────────────────────────────────────────────

export type ElementType = "node" | "way" | "relation" | "nwr" | "nw" | "nr" | "wr";

export type TagFilterOp =
  | "eq"
  | "neq"
  | "regex"
  | "regex_i"
  | "not_regex"
  | "exists"
  | "not_exists";

export interface TagFilter {
  op: TagFilterOp;
  key: string;
  value?: string; // undefined for exists/not_exists
}

export interface NumberNode {
  kind: "number";
  value: number;
  pos: Pos;
}

export interface StringNode {
  kind: "string";
  value: string;
  pos: Pos;
}

export interface BoolNode {
  kind: "bool";
  value: boolean;
  pos: Pos;
}

export interface AtomNode {
  kind: "atom";
  value: string;
  pos: Pos;
}

export interface IdentifierNode {
  kind: "identifier";
  name: string;
  pos: Pos;
}

export interface VarRefNode {
  kind: "var_ref";
  name: string; // includes "$" prefix
  pos: Pos;
}

export interface PointNode {
  kind: "point";
  lat: number | null;
  lng: number | null;
  args: Arg[];
  pos: Pos;
}

export interface BboxNode {
  kind: "bbox";
  s: number | null;
  w: number | null;
  n: number | null;
  e: number | null;
  args: Arg[];
  pos: Pos;
}

export interface GeometryNode {
  kind: "linestring" | "polygon" | "circle";
  items: Expr[];
  pos: Pos;
}

export interface SearchNode {
  kind: "search";
  elementType: ElementType | null;
  filters: TagFilter[];
  methods: MethodNode[];
  pos: Pos;
}

export interface AreaNode {
  kind: "area";
  filters: TagFilter[];
  pos: Pos;
}

export interface ComputationNode {
  kind: "computation";
  name: ComputationName;
  args: Arg[];
  pos: Pos;
}

export type ComputationName =
  | "route"
  | "isochrone"
  | "geocode"
  | "reverse_geocode"
  | "autocomplete"
  | "text_search"
  | "matrix"
  | "map_match"
  | "optimize"
  | "ev_route"
  | "elevation"
  | "elevation_profile"
  | "nearest";

export interface MethodNode {
  kind: "method";
  name: string;
  args: Arg[] | TagFilter[]; // TagFilter[] for filter() method
  pos: Pos;
}

export interface ChainNode {
  kind: "chain";
  receiver: Expr;
  method: MethodNode;
  pos: Pos;
}

export interface ArrowChainNode {
  kind: "arrow_chain";
  items: Expr[];
  pos: Pos;
}

export interface UnionNode {
  kind: "union";
  left: Expr;
  right: Expr;
  pos: Pos;
}

export interface DifferenceNode {
  kind: "difference";
  left: Expr;
  right: Expr;
  pos: Pos;
}

export interface ListNode {
  kind: "list";
  items: Expr[];
  pos: Pos;
}

export interface SettingsNode {
  kind: "settings";
  pairs: Array<{ key: string; value: string | number | boolean }>;
  pos: Pos;
}

export interface VarAssignNode {
  kind: "var_assign";
  name: string; // includes "$" prefix
  expr: Expr;
  pos: Pos;
}

export interface OutputNode {
  kind: "output";
  name: string | null;
  expr: Expr;
  pos: Pos;
}

export type KwArg = { type: "kwarg"; name: string; value: Expr };
export type PosArg = { type: "posarg"; value: Expr };
export type Arg = KwArg | PosArg;

export type Expr =
  | NumberNode
  | StringNode
  | BoolNode
  | AtomNode
  | IdentifierNode
  | VarRefNode
  | PointNode
  | BboxNode
  | GeometryNode
  | SearchNode
  | AreaNode
  | ComputationNode
  | ChainNode
  | ArrowChainNode
  | UnionNode
  | DifferenceNode
  | ListNode;

export type Statement = SettingsNode | VarAssignNode | OutputNode;

export type AstNode = Statement | Expr;

// ── Method Phases ────────────────────────────────────────────────────

export type MethodPhase = {
  ordinal: number;
  label: string;
};

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

export const ALL_METHODS = [
  ...SPATIAL_METHODS,
  "filter",
  ...TRANSFORM_METHODS,
  ...ENRICHMENT_METHODS,
  ...OUTPUT_SHAPE_METHODS,
  ...ORDERING_METHODS,
  ...OUTPUT_MODE_METHODS,
];

export function methodPhase(method: string): MethodPhase {
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

export function isOutputMode(method: string): boolean {
  return OUTPUT_MODE_METHODS.includes(method);
}

export function isSpatialMethod(method: string): boolean {
  return SPATIAL_METHODS.includes(method);
}

export function methodOutputType(
  method: string,
  inputType: PqlType
): { ok: true; type: PqlType } | { ok: false; error: string } {
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
    if (ALL_METHODS.includes(method)) return { ok: true, type: inputType };
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

const CONTAINMENT_TYPES: PqlType[] = [
  "Area",
  "Isochrone",
  "Polygon",
  "PolygonSet",
];

export function validSpatialArgTypes(method: string): PqlType[] {
  if (method === "within" || method === "not_within") return CONTAINMENT_TYPES;
  if (method === "crosses") return ["LineString", "Route", "LineSet"];
  return [...GEOMETRY_TYPES, ...GEO_SET_TYPES];
}

// ── Computation Type Inference ───────────────────────────────────────

const COMPUTATION_TYPES: Record<string, PqlType> = {
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

export function computationType(name: string): PqlType {
  return COMPUTATION_TYPES[name] ?? "GeoSet";
}

export function searchBaseType(elemType: ElementType | null): PqlType {
  if (elemType === "node") return "PointSet";
  return "GeoSet";
}

// ── Method Descriptions (for hover/completions) ─────────────────────

export interface MethodInfo {
  name: string;
  signature: string;
  description: string;
  phase: string;
  ordinal: number;
}

export const METHOD_CATALOG: MethodInfo[] = [
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

export const COMMON_TAG_KEYS = [
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

// ── Function Signatures (for signature help) ─────────────────────────

export interface ParamInfo {
  name: string;
  type: string;
  optional?: boolean;
  description?: string;
}

export interface FunctionSignature {
  name: string;
  params: ParamInfo[];
  returnType: string;
  description: string;
}

export const FUNCTION_SIGNATURES: Record<string, FunctionSignature> = {
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
