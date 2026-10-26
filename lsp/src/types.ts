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
  | "Boundary"
  | "Matrix"
  | "Elevation"
  | "Scalar"
  | "GeoElement"
  | "GroupedSet"

const GEOMETRY_TYPES: PqlType[] = [
  "Point",
  "LineString",
  "Polygon",
  "Route",
  "Isochrone",
  "Boundary",
]
const GEO_SET_TYPES: PqlType[] = ["PointSet", "LineSet", "PolygonSet", "GeoSet"]
const CHAINABLE_TYPES: PqlType[] = [
  ...GEO_SET_TYPES,
  "Route",
  "Isochrone",
  "Boundary",
]
const TERMINAL_TYPES: PqlType[] = ["Matrix", "Elevation", "Scalar"]

export function isGeometric(type: PqlType): boolean {
  return GEOMETRY_TYPES.includes(type)
}

export function isGeoSet(type: PqlType): boolean {
  return GEO_SET_TYPES.includes(type)
}

export function isChainable(type: PqlType): boolean {
  return CHAINABLE_TYPES.includes(type)
}

export function isTerminal(type: PqlType): boolean {
  return TERMINAL_TYPES.includes(type)
}

export function unionType(a: PqlType, b: PqlType): PqlType {
  if (a === b) {
    return a
  }
  return "GeoSet"
}

// ── Source Position ──────────────────────────────────────────────────

export interface Pos {
  line: number // 1-based
  col: number // 1-based
}

// ── AST Nodes ────────────────────────────────────────────────────────

export type ElementType = "node" | "way" | "relation" | "nwr"

export type TagFilterOp =
  | "eq"
  | "neq"
  | "regex"
  | "regex_i"
  | "not_regex"
  | "exists"
  | "not_exists"

export interface TagFilter {
  op: TagFilterOp
  key: string // tag key, or the key regex pattern when keyRegex is true
  value?: string // undefined for exists/not_exists
  keyRegex?: boolean // true for ~"pattern": value filters, which match tag keys by regex
}

export interface NumberNode {
  kind: "number"
  value: number
  pos: Pos
}

export interface StringNode {
  kind: "string"
  value: string
  pos: Pos
}

export interface BoolNode {
  kind: "bool"
  value: boolean
  pos: Pos
}

export interface AtomNode {
  kind: "atom"
  value: string
  pos: Pos
}

export interface IdentifierNode {
  kind: "identifier"
  name: string
  pos: Pos
}

export interface VarRefNode {
  kind: "var_ref"
  name: string // includes "$" prefix
  pos: Pos
}

export interface OutputRefNode {
  kind: "output_ref"
  name: string // the identifier after "$$."
  pos: Pos
}

export interface PointNode {
  kind: "point"
  lat: number | null
  lng: number | null
  args: Arg[]
  pos: Pos
}

export interface BboxNode {
  kind: "bbox"
  s: number | null
  w: number | null
  n: number | null
  e: number | null
  args: Arg[]
  pos: Pos
}

export interface GeometryNode {
  kind: "linestring" | "polygon" | "circle"
  items: Expr[]
  pos: Pos
}

/**
 * `overlap_fraction(geom)` — fraction (0..1) of each feature's area inside a
 * reference polygon. `arg` is the raw geometry argument: polygon(...),
 * bbox(...), $var, or $$.name (anything else is a type error).
 */
export interface OverlapFractionNode {
  kind: "overlap_fraction"
  arg: Expr | null
  pos: Pos
}

/**
 * Opaque filter/value expression (e.g. `number(t["pop"]) * overlap_fraction($a)`).
 * The source text is preserved verbatim for formatting; `calls` lists the
 * `overlap_fraction(...)` calls inside it so they can be type-checked.
 */
export interface ExpressionNode {
  kind: "expression"
  text: string
  calls: OverlapFractionNode[]
  pos: Pos
}

export interface SearchNode {
  kind: "search"
  elementType: ElementType | null
  filters: TagFilter[]
  methods: MethodNode[]
  pos: Pos
}

export interface BoundaryNode {
  kind: "boundary"
  filters: TagFilter[]
  pos: Pos
}

export interface ComputationNode {
  kind: "computation"
  name: ComputationName
  args: Arg[]
  pos: Pos
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
  | "nearest"
  | "centroid"
  | "expansion"
  | "place_lookup"

export interface MethodNode {
  kind: "method"
  name: string
  args: Arg[] | TagFilter[] // TagFilter[] for filter() method
  pos: Pos
}

export interface ChainNode {
  kind: "chain"
  receiver: Expr
  method: MethodNode
  pos: Pos
}

export interface UnionNode {
  kind: "union"
  left: Expr
  right: Expr
  pos: Pos
}

export interface DifferenceNode {
  kind: "difference"
  left: Expr
  right: Expr
  pos: Pos
}

export interface IntersectionNode {
  kind: "intersection"
  left: Expr
  right: Expr
  pos: Pos
}

export interface ListNode {
  kind: "list"
  items: Expr[]
  pos: Pos
}

export interface SettingsNode {
  kind: "settings"
  pairs: Array<{ key: string; value: string | number | boolean }>
  pos: Pos
}

export interface VarAssignNode {
  kind: "var_assign"
  name: string // includes "$" prefix
  expr: Expr
  pos: Pos
}

export interface OutputNode {
  kind: "output"
  name: string | null
  expr: Expr
  pos: Pos
}

export interface BareOutputNode {
  kind: "bare_output"
  expr: Expr
  pos: Pos
}

export type KwArg = { type: "kwarg"; name: string; value: Expr }
export type PosArg = { type: "posarg"; value: Expr }
export type Arg = KwArg | PosArg

export type Expr =
  | NumberNode
  | StringNode
  | BoolNode
  | AtomNode
  | IdentifierNode
  | VarRefNode
  | OutputRefNode
  | PointNode
  | BboxNode
  | GeometryNode
  | SearchNode
  | BoundaryNode
  | ComputationNode
  | ChainNode
  | UnionNode
  | DifferenceNode
  | IntersectionNode
  | ListNode
  | OverlapFractionNode
  | ExpressionNode

export type Statement =
  | SettingsNode
  | VarAssignNode
  | OutputNode
  | BareOutputNode

export type AstNode = Statement | Expr

// ── Method Phases ────────────────────────────────────────────────────

export type MethodPhase = {
  ordinal: number
  label: string
}

const SPATIAL_METHODS = [
  "within",
  "not_within",
  "around",
  "bbox",
  "h3",
  "intersects",
  "not_intersects",
  "contains",
  "not_contains",
  "crosses",
  "touches",
  "member_of",
  "has_member",
]
const TRANSFORM_METHODS = ["buffer", "simplify", "centroid"]
const COMPUTED_METHODS = [
  "elevation",
  "distance",
  "area",
  "length",
  "overlap_fraction",
]
const OUTPUT_SHAPE_METHODS = [
  "fields",
  "include",
  "precision",
  "expand",
  "geometry",
]
const ORDERING_METHODS = ["sort", "limit", "offset", "cursor"]
const OUTPUT_MODE_METHODS = [
  "count",
  "ids",
  "tags",
  "skel",
  "geom",
  "tile",
  "sum",
  "min",
  "max",
  "avg",
]
const NARROWING_METHODS = ["first", "last", "index"]
const GROUP_BY_METHODS = ["group_by"]

export const ALL_METHODS = [
  ...SPATIAL_METHODS,
  "filter",
  ...TRANSFORM_METHODS,
  ...COMPUTED_METHODS,
  ...OUTPUT_SHAPE_METHODS,
  ...ORDERING_METHODS,
  ...OUTPUT_MODE_METHODS,
  ...NARROWING_METHODS,
  ...GROUP_BY_METHODS,
]

export function methodPhase(method: string): MethodPhase {
  if (SPATIAL_METHODS.includes(method)) {
    return { ordinal: 3, label: "spatial (phase 3)" }
  }
  if (method === "filter") {
    return { ordinal: 3.5, label: "tag filter (phase 3b)" }
  }
  if (TRANSFORM_METHODS.includes(method)) {
    return { ordinal: 4, label: "transform (phase 4)" }
  }
  if (COMPUTED_METHODS.includes(method)) {
    return { ordinal: 5, label: "computed (phase 5)" }
  }
  if (OUTPUT_SHAPE_METHODS.includes(method)) {
    return { ordinal: 6, label: "output shape (phase 6)" }
  }
  if (ORDERING_METHODS.includes(method)) {
    return { ordinal: 7, label: "ordering (phase 7)" }
  }
  if (OUTPUT_MODE_METHODS.includes(method)) {
    return { ordinal: 8, label: "output mode (phase 8)" }
  }
  if (NARROWING_METHODS.includes(method)) {
    return { ordinal: 7.5, label: "narrowing (phase 7b)" }
  }
  if (GROUP_BY_METHODS.includes(method)) {
    return { ordinal: 7.5, label: "group by (phase 7b)" }
  }
  return { ordinal: 0, label: "unknown" }
}

export type MethodGroup =
  | "source"
  | "freely_orderable"
  | "late_chain"
  | "terminal"

export function methodGroup(method: string): MethodGroup {
  if (ORDERING_METHODS.includes(method)) {
    return "late_chain"
  }
  if (NARROWING_METHODS.includes(method)) {
    return "late_chain"
  }
  if (GROUP_BY_METHODS.includes(method)) {
    return "late_chain"
  }
  if (OUTPUT_MODE_METHODS.includes(method)) {
    return "terminal"
  }
  return "freely_orderable"
}

export function methodCategory(method: string): string {
  if (SPATIAL_METHODS.includes(method)) {
    return "spatial"
  }
  if (method === "filter") {
    return "filter"
  }
  if (TRANSFORM_METHODS.includes(method)) {
    return "transform"
  }
  if (COMPUTED_METHODS.includes(method)) {
    return "computed"
  }
  if (OUTPUT_SHAPE_METHODS.includes(method)) {
    return "output shape"
  }
  if (ORDERING_METHODS.includes(method)) {
    return "ordering"
  }
  if (OUTPUT_MODE_METHODS.includes(method)) {
    return "output mode"
  }
  if (NARROWING_METHODS.includes(method)) {
    return "narrowing"
  }
  if (GROUP_BY_METHODS.includes(method)) {
    return "group by"
  }
  return "unknown"
}

export function isOutputMode(method: string): boolean {
  return OUTPUT_MODE_METHODS.includes(method)
}

export function isSpatialMethod(method: string): boolean {
  return SPATIAL_METHODS.includes(method)
}

const METHOD_OUTPUT_OVERRIDES: Record<string, PqlType> = {
  centroid: "PointSet",
  buffer: "PolygonSet",
  count: "Scalar",
  ids: "Scalar",
  tags: "Scalar",
  skel: "Scalar",
  geom: "Scalar",
  tile: "Scalar",
  first: "GeoElement",
  last: "GeoElement",
  index: "GeoElement",
  sum: "Scalar",
  min: "Scalar",
  max: "Scalar",
  avg: "Scalar",
  group_by: "GroupedSet",
}

// Methods valid after .group_by(), as in the Elixir checker (Types.method_output_type/2)
const AGGREGATION_METHODS = ["count", "sum", "min", "max", "avg"]

export function methodOutputType(
  method: string,
  inputType: PqlType,
): { ok: true; type: PqlType } | { ok: false; error: string } {
  if (method === "tile" && !isGeoSet(inputType)) {
    return {
      ok: false,
      error: `\`.tile()\` cannot be applied to ${inputType} — it renders the results of a \`search(...)\` as a vector tile`,
    }
  }
  const override = METHOD_OUTPUT_OVERRIDES[method]
  if (override) {
    const allowGroupedSet =
      AGGREGATION_METHODS.includes(method) && inputType === "GroupedSet"
    if (isChainable(inputType) || allowGroupedSet) {
      return { ok: true, type: override }
    }
  }
  if (isChainable(inputType)) {
    if (ALL_METHODS.includes(method)) {
      return { ok: true, type: inputType }
    }
    return { ok: false, error: `unknown method \`.${method}()\`` }
  }
  if (isTerminal(inputType)) {
    return {
      ok: false,
      error: `\`.${method}()\` cannot be applied to ${inputType} — ${inputType} is a terminal type that does not support chaining`,
    }
  }
  return {
    ok: false,
    error: `\`.${method}()\` cannot be applied to ${inputType}`,
  }
}

const CONTAINMENT_TYPES: PqlType[] = [
  "Boundary",
  "Isochrone",
  "Polygon",
  "PolygonSet",
]

export function validSpatialArgTypes(method: string): PqlType[] {
  if (method === "within" || method === "not_within") {
    return CONTAINMENT_TYPES
  }
  if (method === "crosses") {
    return ["LineString", "Route", "LineSet"]
  }
  return [...GEOMETRY_TYPES, ...GEO_SET_TYPES]
}

// ── Computation Type Inference ───────────────────────────────────────

const COMPUTATION_TYPES: Record<string, PqlType> = {
  route: "Route",
  // biome-ignore lint/style/useNamingConvention: PQL name
  map_match: "Route",
  optimize: "Route",
  // biome-ignore lint/style/useNamingConvention: PQL name
  ev_route: "Route",
  isochrone: "Isochrone",
  geocode: "PointSet",
  // biome-ignore lint/style/useNamingConvention: PQL name
  reverse_geocode: "PointSet",
  autocomplete: "PointSet",
  // biome-ignore lint/style/useNamingConvention: PQL name
  text_search: "PointSet",
  nearest: "PointSet",
  matrix: "Matrix",
  elevation: "Elevation",
  // biome-ignore lint/style/useNamingConvention: PQL name
  elevation_profile: "Elevation",
  centroid: "PointSet",
  expansion: "LineSet",
  // biome-ignore lint/style/useNamingConvention: PQL name
  place_lookup: "PointSet",
}

export function computationType(name: string): PqlType {
  return COMPUTATION_TYPES[name] ?? "GeoSet"
}

export function searchBaseType(elemType: ElementType | null): PqlType {
  if (elemType === "node") {
    return "PointSet"
  }
  return "GeoSet"
}

// ── Method Descriptions (for hover/completions) ─────────────────────

export interface MethodInfo {
  name: string
  signature: string
  description: string
  phase: string
  ordinal: number
  group: MethodGroup
}

export const METHOD_CATALOG: MethodInfo[] = [
  // Spatial
  {
    name: "within",
    signature: ".within(geometry: Boundary | Polygon | Isochrone)",
    description: "Filter to features fully inside the geometry.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "not_within",
    signature: ".not_within(geometry: Boundary | Polygon | Isochrone)",
    description: "Exclude features inside the geometry.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "around",
    signature: ".around(distance: number, geometry?: Point | Boundary)",
    description:
      "Filter to features within distance (meters) of a point or geometry.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "bbox",
    signature: ".bbox(s: number, w: number, n: number, e: number)",
    description: "Filter to features within a bounding box.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "h3",
    signature: ".h3(cell: string)",
    description: "Filter to features within an H3 cell.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "intersects",
    signature: ".intersects(geometry: Geometry)",
    description: "Filter to features that intersect the geometry.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "not_intersects",
    signature: ".not_intersects(geometry: Geometry)",
    description: "Exclude features that intersect the geometry.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "contains",
    signature: ".contains(geometry: Geometry)",
    description: "Filter to features that contain the geometry.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "not_contains",
    signature: ".not_contains(geometry: Geometry)",
    description: "Exclude features that contain the geometry.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "crosses",
    signature: ".crosses(geometry: LineString | Route)",
    description: "Filter to features that cross the geometry.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "touches",
    signature: ".touches(geometry: Geometry)",
    description: "Filter to features that touch the geometry.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  // Tag filter
  {
    name: "filter",
    signature: ".filter(key: value, ...)",
    description: "Post-search/post-union tag filtering.",
    phase: "Tag Filter",
    ordinal: 3.5,
    group: "freely_orderable",
  },
  // Transform
  {
    name: "buffer",
    signature: ".buffer(meters: number)",
    description: "Expand geometries by a buffer distance.",
    phase: "Transform",
    ordinal: 4,
    group: "freely_orderable",
  },
  {
    name: "simplify",
    signature: ".simplify(tolerance: number)",
    description: "Simplify geometries by reducing coordinate precision.",
    phase: "Transform",
    ordinal: 4,
    group: "freely_orderable",
  },
  {
    name: "centroid",
    signature: ".centroid()",
    description:
      "Replace geometries with their centroids. Result type becomes PointSet.",
    phase: "Transform",
    ordinal: 4,
    group: "freely_orderable",
  },
  // Enrichment
  {
    name: "elevation",
    signature: ".elevation()",
    description: "Add elevation as a computed column on each feature.",
    phase: "Computed",
    ordinal: 5,
    group: "freely_orderable",
  },
  {
    name: "distance",
    signature: ".distance(geometry: Point)",
    description:
      "Add distance from a reference point as a computed column on each feature.",
    phase: "Computed",
    ordinal: 5,
    group: "freely_orderable",
  },
  {
    name: "overlap_fraction",
    signature: ".overlap_fraction(geometry: Polygon | Bbox | $var)",
    description:
      'Add the fraction (0..1) of each feature\'s area that lies inside the reference polygon as a computed `overlap_fraction` column. Also usable as an expression: `.sum(number(t["population"]) * overlap_fraction($area))`.',
    phase: "Computed",
    ordinal: 5,
    group: "freely_orderable",
  },
  {
    name: "area",
    signature: ".area()",
    description: "Add geometry area as a computed column on polygon features.",
    phase: "Computed",
    ordinal: 5,
    group: "freely_orderable",
  },
  {
    name: "length",
    signature: ".length()",
    description: "Add geometry length as a computed column on line features.",
    phase: "Computed",
    ordinal: 5,
    group: "freely_orderable",
  },
  // Output shape
  {
    name: "fields",
    signature: ".fields(field1, field2, ...)",
    description: "Select specific tag fields to include in output.",
    phase: "Output Shape",
    ordinal: 6,
    group: "freely_orderable",
  },
  {
    name: "include",
    signature: '.include("bbox" | "center" | "distance", ...)',
    description:
      'Add computed fields to each feature: `"bbox"` (feature bounding box), `"center"` (`center_lat`/`center_lng`), `"distance"` (`distance_m`, with `.distance()` or `.around()`).',
    phase: "Output Shape",
    ordinal: 6,
    group: "freely_orderable",
  },
  {
    name: "geometry",
    signature: ".geometry(keep: boolean)",
    description:
      "`.geometry(false)` returns properties only, with a null geometry on each feature.",
    phase: "Output Shape",
    ordinal: 6,
    group: "freely_orderable",
  },
  {
    name: "precision",
    signature: ".precision(digits: number)",
    description: "Set coordinate precision for output.",
    phase: "Output Shape",
    ordinal: 6,
    group: "freely_orderable",
  },
  {
    name: "expand",
    signature: ".expand(direction: :down | :up)",
    description: "Expand relations to their members or ways to their nodes.",
    phase: "Output Shape",
    ordinal: 6,
    group: "freely_orderable",
  },
  // Ordering
  {
    name: "sort",
    signature: ".sort(expr, order?: :asc | :desc)",
    description:
      'Sort results by an expression (e.g., `t["name"]`, `distance()`, `area()`).',
    phase: "Ordering",
    ordinal: 7,
    group: "late_chain",
  },
  {
    name: "limit",
    signature: ".limit(n: number)",
    description: "Limit the number of results.",
    phase: "Ordering",
    ordinal: 7,
    group: "late_chain",
  },
  {
    name: "offset",
    signature: ".offset(n: number)",
    description: "Skip the first n results. Requires `.limit()` first.",
    phase: "Ordering",
    ordinal: 7,
    group: "late_chain",
  },
  {
    name: "cursor",
    signature: ".cursor(token: string)",
    description:
      "Continue from the previous page: pass the `next_cursor` the server returned with it. The cursor only works with the query that issued it. Cannot be combined with `.offset()`.",
    phase: "Ordering",
    ordinal: 7,
    group: "late_chain",
  },
  // Output mode
  {
    name: "count",
    signature: ".count()",
    description:
      "Return only the count of matching features. Result type becomes Scalar.",
    phase: "Output Mode",
    ordinal: 8,
    group: "terminal",
  },
  {
    name: "ids",
    signature: ".ids()",
    description: "Return only OSM IDs.",
    phase: "Output Mode",
    ordinal: 8,
    group: "terminal",
  },
  {
    name: "tags",
    signature: ".tags()",
    description: "Return only tags (no geometry).",
    phase: "Output Mode",
    ordinal: 8,
    group: "terminal",
  },
  {
    name: "skel",
    signature: ".skel()",
    description: "Return skeleton (IDs + minimal geometry).",
    phase: "Output Mode",
    ordinal: 8,
    group: "terminal",
  },
  {
    name: "geom",
    signature: ".geom()",
    description: "Full geometry, no tags",
    phase: "Output Mode",
    ordinal: 8,
    group: "terminal",
  },
  {
    name: "tile",
    signature: ".tile(z, x, y, layers?: [string])",
    description:
      "Render the results as one Mapbox Vector Tile at z/x/y, like GET /api/v1/tiles/{z}/{x}/{y}",
    phase: "Output Mode",
    ordinal: 8,
    group: "terminal",
  },
  // Aggregation
  {
    name: "sum",
    signature: ".sum(expr)",
    description: "Sum of expression values. Result type becomes Scalar",
    phase: "Aggregation",
    ordinal: 8,
    group: "terminal",
  },
  {
    name: "min",
    signature: ".min(expr)",
    description: "Minimum expression value. Result type becomes Scalar",
    phase: "Aggregation",
    ordinal: 8,
    group: "terminal",
  },
  {
    name: "max",
    signature: ".max(expr)",
    description: "Maximum expression value. Result type becomes Scalar",
    phase: "Aggregation",
    ordinal: 8,
    group: "terminal",
  },
  {
    name: "avg",
    signature: ".avg(expr)",
    description: "Average expression value. Result type becomes Scalar",
    phase: "Aggregation",
    ordinal: 8,
    group: "terminal",
  },
  // Group By
  {
    name: "group_by",
    signature: ".group_by(expr)",
    description:
      "Partition results by expression, then apply aggregation. Result type becomes GroupedSet",
    phase: "Group By",
    ordinal: 7.5,
    group: "late_chain",
  },
  // Structural joins
  {
    name: "member_of",
    signature: ".member_of(source, role?: string)",
    description:
      "Filter to elements that are members of the source set. Works with OSM relations and ways.",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  {
    name: "has_member",
    signature: ".has_member(source, role?: string)",
    description:
      "Filter to elements that contain the source elements as members. Reverse of .member_of().",
    phase: "Spatial",
    ordinal: 3,
    group: "freely_orderable",
  },
  // Narrowing
  {
    name: "first",
    signature: ".first()",
    description:
      "Narrow set to its first element. Transforms GeoSet to GeoElement.",
    phase: "Narrowing",
    ordinal: 7.5,
    group: "late_chain",
  },
  {
    name: "last",
    signature: ".last()",
    description:
      "Narrow set to its last element. Transforms GeoSet to GeoElement.",
    phase: "Narrowing",
    ordinal: 7.5,
    group: "late_chain",
  },
  {
    name: "index",
    signature: ".index(n: number)",
    description:
      "Narrow set to its nth element (1-indexed). Transforms GeoSet to GeoElement.",
    phase: "Narrowing",
    ordinal: 7.5,
    group: "late_chain",
  },
]

// ── Function Signatures (for signature help) ─────────────────────────

export interface ParamInfo {
  name: string
  type: string
  optional?: boolean
  description?: string
  enumValues?: Array<{ value: string; description?: string }>
}

export interface FunctionSignature {
  name: string
  params: ParamInfo[]
  returnType: string
  description: string
}

/** Values accepted by `geocode(layers: ...)` and `autocomplete(layers: ...)`. */
export const GEOCODE_LAYERS = [
  "address",
  "admin",
  "place",
  "poi",
  "street",
  "postalcode",
  "neighbourhood",
  "locality",
  "county",
  "region",
  "country",
  "dataset",
]

/** Structured components accepted by `geocode(...)`. */
export const STRUCTURED_GEOCODE_COMPONENTS = [
  "address",
  "neighbourhood",
  "locality",
  "county",
  "region",
  "postalcode",
  "country",
]

const GEOCODE_LAYER_VALUES = GEOCODE_LAYERS.map((layer) => ({
  value: `"${layer}"`,
}))

// Vehicle options of route(), isochrone(), matrix(), optimize(), centroid(),
// expansion() and map_match() with mode: "truck" (Plaza's `truck` object).
// Plaza checks the ranges.
export const TRUCK_DIMENSIONS = [
  "height",
  "width",
  "length",
  "weight",
  "axle_load",
]
export const TRUCK_OPTIONS = [...TRUCK_DIMENSIONS, "axle_count", "hazmat"]
export const TRUCK_COMPUTATIONS = [
  "route",
  "isochrone",
  "matrix",
  "optimize",
  "centroid",
  "expansion",
  "map_match",
]
/** The computations that take every vehicle mode, as a message lists them. */
export const VEHICLE_COMPUTATION_NAMES =
  "`route()`, `isochrone()`, `matrix()`, `optimize()`, `centroid()`, `expansion()` and `map_match()`"

const TRUCK_PARAMS: ParamInfo[] = [
  {
    name: "height",
    type: "number",
    optional: true,
    description:
      'Truck height in metres (mode: "truck"; default 4.11, at most 10)',
  },
  {
    name: "width",
    type: "number",
    optional: true,
    description:
      'Truck width in metres (mode: "truck"; default 2.6, at most 10)',
  },
  {
    name: "length",
    type: "number",
    optional: true,
    description:
      'Truck length in metres (mode: "truck"; default 21.64, at most 60)',
  },
  {
    name: "weight",
    type: "number",
    optional: true,
    description:
      'Gross weight in tonnes (mode: "truck"; default 21.77, at most 200)',
  },
  {
    name: "axle_load",
    type: "number",
    optional: true,
    description:
      'Heaviest axle load in tonnes (mode: "truck"; at most 50; else weight / axle_count)',
  },
  {
    name: "axle_count",
    type: "number",
    optional: true,
    description: 'Number of axles, 2 to 20 (mode: "truck")',
  },
  {
    name: "hazmat",
    type: "boolean",
    optional: true,
    description:
      'Carrying hazardous materials: avoids hazmat=no roads and ADR category B-E tunnels (mode: "truck")',
  },
]

const TRUCK_MODE_VALUES = [
  { value: '"auto"' },
  { value: '"foot"' },
  { value: '"bicycle"' },
  { value: '"truck"' },
  { value: '"motorcycle"' },
  { value: '"motor_scooter"' },
]

// Options of route() and isochrone() with mode: "transit" (Plaza's
// pedestrian + public transit routing over GTFS feeds). Plaza checks the
// upper bounds. `arrive_by` is route() only; isochrone() recognises it to
// say so. `wheelchair` is a transit option too, but as a foot option it is
// checked with the mode options (TRANSIT_ACTIVE_OPTIONS).
export const TRANSIT_PREFERENCES = ["use_bus", "use_rail", "use_transfers"]
export const TRANSIT_OPTIONS = [
  ...TRANSIT_PREFERENCES,
  "max_walk_m",
  "max_transfers",
  "arrive_by",
]
export const TRANSIT_COMPUTATIONS = ["route", "isochrone"]

const TRANSIT_PARAMS: ParamInfo[] = [
  {
    name: "use_bus",
    type: "number",
    optional: true,
    description:
      'Bus preference, 0 to 1 (mode: "transit"; default 1). 0 never rides a bus; lower values count bus time more.',
  },
  {
    name: "use_rail",
    type: "number",
    optional: true,
    description:
      'Rail preference (tram, subway, rail), 0 to 1 (mode: "transit"; default 1). 0 never rides rail.',
  },
  {
    name: "use_transfers",
    type: "number",
    optional: true,
    description:
      'Transfer willingness, 0 to 1 (mode: "transit"; default 1). 0 allows no transfer; lower values add a penalty per transfer.',
  },
  {
    name: "max_walk_m",
    type: "number",
    optional: true,
    description:
      'Longest walk in meters to the first stop, between stops and from the last stop (mode: "transit"; default 1000, at most 3000)',
  },
  {
    name: "max_transfers",
    type: "number",
    optional: true,
    description:
      'Most changes between vehicles (mode: "transit"; default 3, at most 4)',
  },
]

const ARRIVE_BY_PARAM: ParamInfo = {
  name: "arrive_by",
  type: "string",
  optional: true,
  description:
    'Arrival time for mode "transit" (ISO 8601 with an offset, local time at the feed without one): finds the latest departure that arrives by then. Not with depart_at.',
}

const TRANSIT_MODE_VALUE = { value: '"transit"' }

// Rider options of route(), isochrone() and matrix() with mode: "bicycle"
// (Plaza's POST /route `bicycle` object), walker options with mode: "foot"
// (its `pedestrian` object), motorcycle options with mode: "motorcycle"
// (its `motorcycle` object) and scooter options with mode: "motor_scooter"
// (its `motor_scooter` object). `use_hills` is bicycle, foot and scooter.
export const BICYCLE_OPTIONS = [
  "bicycle_type",
  "cycling_speed",
  "use_roads",
  "use_hills",
  "avoid_bad_surfaces",
]
export const PEDESTRIAN_OPTIONS = [
  "walking_speed",
  "use_hills",
  "use_lit",
  "walkway_factor",
  "sidewalk_factor",
  "step_penalty",
  "max_hiking_difficulty",
  "wheelchair",
]
// Transit walks take the pedestrian options (wheelchair included).
export const TRANSIT_ACTIVE_OPTIONS = PEDESTRIAN_OPTIONS
export const MOTORCYCLE_OPTIONS = ["style", "use_trails", "use_curves"]
export const MOTOR_SCOOTER_OPTIONS = ["use_primary", "use_hills"]
export const ACTIVE_OPTIONS = [
  ...new Set([
    ...BICYCLE_OPTIONS,
    ...PEDESTRIAN_OPTIONS,
    ...MOTORCYCLE_OPTIONS,
    ...MOTOR_SCOOTER_OPTIONS,
  ]),
]
export const ACTIVE_COMPUTATIONS = TRUCK_COMPUTATIONS
export const BICYCLE_MODES = ["bicycle", "bike"]
export const FOOT_MODES = ["foot", "walk"]
export const MOTORCYCLE_MODES = ["motorcycle", "motorbike"]
export const MOTOR_SCOOTER_MODES = ["motor_scooter", "scooter", "moped"]
export const MOTORCYCLE_STYLES = ["touring", "adventure"]
export const BICYCLE_TYPES = ["road", "hybrid", "cross", "mountain"]

/** [min, max, unit] of the numeric bicycle and pedestrian options. */
export const ACTIVE_RANGES = new Map<string, [number, number, string | null]>([
  ["cycling_speed", [5, 50, "km/h"]],
  ["use_roads", [0, 1, null]],
  ["use_hills", [0, 1, null]],
  ["avoid_bad_surfaces", [0, 1, null]],
  ["walking_speed", [1, 10, "km/h"]],
  ["use_lit", [0, 1, null]],
  ["walkway_factor", [0.1, 10, null]],
  ["sidewalk_factor", [0.1, 10, null]],
  ["step_penalty", [0, 3600, "seconds"]],
  ["use_trails", [0, 1, null]],
  ["use_curves", [0, 1, null]],
  ["use_primary", [0, 1, null]],
])

const ACTIVE_PARAMS: ParamInfo[] = [
  {
    name: "bicycle_type",
    type: "string",
    optional: true,
    description:
      'Bike type (mode: "bicycle"; default "hybrid"): sets cruising speed and how much rough surfaces slow it',
    enumValues: BICYCLE_TYPES.map((type) => ({ value: `"${type}"` })),
  },
  {
    name: "cycling_speed",
    type: "number",
    optional: true,
    description: 'Cruising speed in km/h (mode: "bicycle"; 5 to 50)',
  },
  {
    name: "use_roads",
    type: "number",
    optional: true,
    description:
      'Willingness to ride busy roads without cycle lanes, 0 to 1 (mode: "bicycle"; default 0.5)',
  },
  {
    name: "use_hills",
    type: "number",
    optional: true,
    description:
      'Willingness to climb, 0 to 1 (mode: "bicycle", "foot" or "motor_scooter"; default 0.5). Needs elevation data.',
  },
  {
    name: "avoid_bad_surfaces",
    type: "number",
    optional: true,
    description:
      'How much to avoid unpaved and rough ways, 0 to 1 (mode: "bicycle"; default 0.25)',
  },
  {
    name: "walking_speed",
    type: "number",
    optional: true,
    description: 'Walking speed in km/h (mode: "foot"; default 5, 1 to 10)',
  },
  {
    name: "use_lit",
    type: "number",
    optional: true,
    description: 'Preference for lit ways, 0 to 1 (mode: "foot"; default 0)',
  },
  {
    name: "walkway_factor",
    type: "number",
    optional: true,
    description:
      'Cost multiplier for footways and paths, 0.1 to 10 (mode: "foot"; default 1; below 1 prefers them)',
  },
  {
    name: "sidewalk_factor",
    type: "number",
    optional: true,
    description:
      'Cost multiplier for roads with a sidewalk, 0.1 to 10 (mode: "foot"; default 1)',
  },
  {
    name: "step_penalty",
    type: "number",
    optional: true,
    description:
      'Seconds added to the cost of each flight of steps (mode: "foot"; default 30, at most 3600)',
  },
  {
    name: "max_hiking_difficulty",
    type: "number",
    optional: true,
    description:
      'Hardest SAC-scale trail to use, 1 (hiking) to 6 (mode: "foot"; default 1)',
  },
  {
    name: "wheelchair",
    type: "boolean",
    optional: true,
    description:
      'Wheelchair routing. mode "foot": no steps, grades of 8% at most, smooth surfaces. mode "transit": rides only wheelchair-accessible trips and boards and alights only at accessible stops (unknown counts as not accessible)',
  },
  {
    name: "style",
    type: "string",
    optional: true,
    description:
      'Riding style (mode: "motorcycle"; default "touring"): "touring" keeps to direct, paved roads, "adventure" seeks curvy roads and accepts tracks',
    enumValues: MOTORCYCLE_STYLES.map((style) => ({ value: `"${style}"` })),
  },
  {
    name: "use_trails",
    type: "number",
    optional: true,
    description:
      'Willingness to ride tracks, 0 to 1 (mode: "motorcycle"; default 0 touring, 0.5 adventure; 0 keeps to roads)',
  },
  {
    name: "use_curves",
    type: "number",
    optional: true,
    description:
      'Preference for curvy roads, 0 (avoid) to 1 (seek); 0.5 is neutral (mode: "motorcycle"; default 0.5 touring, 0.8 adventure). Steers the route, not its duration.',
  },
  {
    name: "use_primary",
    type: "number",
    optional: true,
    description:
      'Willingness to ride primary and trunk roads and roads with limits of 80 km/h or more, 0 to 1 (mode: "motor_scooter"; default 0.2). Steers the route, not its duration.',
  },
]

// Road costing options of route(), ev_route() and matrix() (isochrone()
// takes the speed overrides only), as Plaza's REST costing options. Plaza
// checks which modes take which.
export const COSTING_PREFERENCES = [
  "use_highways",
  "use_tolls",
  "use_ferries",
  "use_living_streets",
  "use_tracks",
]
export const COSTING_SPEEDS = ["top_speed", "fixed_speed"]
export const COSTING_PENALTIES = [
  "maneuver_penalty",
  "service_penalty",
  "gate_cost",
  "toll_booth_cost",
  "country_crossing_cost",
]
export const COSTING_OPTIONS = [
  ...COSTING_PREFERENCES,
  "shortest",
  ...COSTING_SPEEDS,
  ...COSTING_PENALTIES,
]
// Per-point route() options: one entry per point (origin, waypoints,
// destination), as a list or a ";"-separated string.
export const LOCATION_OPTIONS = [
  "location_types",
  "headings",
  "heading_tolerances",
  "preferred_sides",
  "approaches",
]

const preferenceParam = (name: string, what: string, modes: string) => ({
  name,
  type: "number",
  optional: true,
  description: `How much to use ${what}, 0 (avoid) to 1 (prefer); 0.5 or leaving it out prices them as usual. Steers the route, not its duration. ${modes}.`,
})

const SPEED_PARAMS: ParamInfo[] = [
  {
    name: "top_speed",
    type: "number",
    optional: true,
    description:
      'Highest speed the vehicle drives, whole km/h from 10 to 252 (mode "auto", "truck", "motorcycle" or "motor_scooter"; a scooter defaults to 45)',
  },
  {
    name: "fixed_speed",
    type: "number",
    optional: true,
    description:
      'Drive every road at this speed, whole km/h from 1 to 252, ignoring class, limits, surface, grade and traffic (mode "auto", "truck", "motorcycle" or "motor_scooter")',
  },
]

const COSTING_PARAMS: ParamInfo[] = [
  preferenceParam(
    "use_highways",
    "motorways and trunk roads",
    'Mode "auto", "truck", "motorcycle" or "motor_scooter"',
  ),
  preferenceParam(
    "use_tolls",
    "toll roads",
    'Mode "auto", "truck", "motorcycle" or "motor_scooter"',
  ),
  preferenceParam("use_ferries", "ferries", "Every mode"),
  preferenceParam("use_living_streets", "living streets", "Every mode"),
  preferenceParam("use_tracks", "tracks", 'Mode "foot" or "bicycle"'),
  {
    name: "shortest",
    type: "boolean",
    optional: true,
    description:
      "Minimise distance instead of time; not with the use_* or penalty options",
  },
  ...SPEED_PARAMS,
  {
    name: "maneuver_penalty",
    type: "number",
    optional: true,
    description:
      'Seconds added at each intersection the route arrives at, 0 to 3600 (mode "auto", "truck", "motorcycle" or "motor_scooter"); steers, not part of the duration',
  },
  {
    name: "service_penalty",
    type: "number",
    optional: true,
    description:
      'Seconds added for each service road used, 0 to 3600 (mode "auto", "truck", "motorcycle" or "motor_scooter"); steers, not part of the duration',
  },
  {
    name: "gate_cost",
    type: "number",
    optional: true,
    description:
      "Seconds added for each gate passed (barrier=gate, lift_gate, swing_gate, sliding_gate or hampshire_gate without access=yes, permissive, designated or public), 0 to 3600 (every mode); steers, not part of the duration",
  },
  {
    name: "toll_booth_cost",
    type: "number",
    optional: true,
    description:
      'Seconds added for each toll booth (barrier=toll_booth) passed, 0 to 3600 (mode "auto", "truck", "motorcycle" or "motor_scooter"). A booth already costs 15 s of travel time; this only steers the route',
  },
  {
    name: "country_crossing_cost",
    type: "number",
    optional: true,
    description:
      "Seconds added for each country border crossed (a barrier=border_control node, or roads of two countries meeting), 0 to 3600 (every mode); steers, not part of the duration",
  },
]

const LOCATION_PARAMS: ParamInfo[] = [
  {
    name: "location_types",
    type: "string[] | string",
    optional: true,
    description:
      'One per point: "break" (a stop; default, required at both ends), "through" (pass without stopping or turning back) or "via" (pass, may turn back)',
  },
  {
    name: "headings",
    type: "number[] | string",
    optional: true,
    description:
      'Direction of travel at each point, degrees from north; a ";"-separated string leaves points out ("90;;")',
  },
  {
    name: "heading_tolerances",
    type: "number[] | string",
    optional: true,
    description:
      "Largest difference from each heading accepted, degrees (default 60)",
  },
  {
    name: "preferred_sides",
    type: "string[] | string",
    optional: true,
    description:
      'Side of the road for each point: "same" (driving side), "opposite" or "either" (default)',
  },
  {
    name: "approaches",
    type: "string[] | string",
    optional: true,
    description:
      'How the route reaches each point: "curb" (on the driving side, as preferred_sides "same") or "unrestricted" (default)',
  },
  {
    name: "recostings",
    type: "string[]",
    optional: true,
    description:
      'Price the route under other costing models: "name: key=value, ...", e.g. ["no_tolls: use_tolls=0", "walk: mode=foot"]',
  },
]

export const FUNCTION_SIGNATURES: Record<string, FunctionSignature> = {
  search: {
    name: "search",
    params: [
      {
        name: "type",
        type: "node | way | relation | nwr",
        optional: true,
        description: "Element type to search",
      },
      {
        name: "...filters",
        type: "TagFilter",
        optional: true,
        description: "Tag key: value filters",
      },
    ],
    returnType: "GeoSet",
    description: "Search for OSM features matching tag filters.",
  },
  boundary: {
    name: "boundary",
    params: [
      {
        name: "...filters",
        type: "TagFilter",
        description:
          'Tag filters to identify the boundary (e.g., name: "Berlin")',
      },
    ],
    returnType: "Boundary",
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
      {
        name: "...points",
        type: "Point",
        description: "Three or more points (auto-closed)",
      },
    ],
    returnType: "Polygon",
    description: "Create a polygon from a ring of points.",
  },
  route: {
    name: "route",
    params: [
      { name: "origin", type: "Point", description: "Starting point" },
      { name: "destination", type: "Point", description: "Ending point" },
      {
        name: "waypoints",
        type: "Point[]",
        optional: true,
        description: "Intermediate waypoints",
      },
      {
        name: "mode",
        type: '"auto" | "car" | "bicycle" | "foot" | "truck" | "motorcycle" | "motor_scooter" | "transit"',
        optional: true,
        description: "Travel mode",
        enumValues: [
          { value: '"auto"' },
          { value: '"foot"' },
          { value: '"bicycle"' },
          { value: '"truck"' },
          { value: '"motorcycle"' },
          { value: '"motor_scooter"' },
          TRANSIT_MODE_VALUE,
          { value: '"car"' },
        ],
      },
      {
        name: "depart_at",
        type: "string",
        optional: true,
        description:
          'Departure time (ISO 8601, e.g. "2026-03-16T08:00:00Z", or "now") for time-of-day traffic; with mode "transit", a time without an offset is local time at the transit feed',
      },
      {
        name: "traffic_model",
        type: '"best_guess" | "optimistic" | "pessimistic"',
        optional: true,
        description: "Traffic speed assumption; applies when depart_at is set",
        enumValues: [
          { value: '"best_guess"' },
          { value: '"optimistic"' },
          { value: '"pessimistic"' },
        ],
      },
      {
        name: "exclude",
        type: "string[]",
        optional: true,
        description:
          'Road types to avoid: "toll", "cash_only_tolls" (toll booths taking only cash), "ferry", "unpaved", "motorway", "trunk", "primary", "secondary", "tertiary"',
      },
      ...TRUCK_PARAMS,
      ...TRANSIT_PARAMS,
      ARRIVE_BY_PARAM,
      ...ACTIVE_PARAMS,
      ...COSTING_PARAMS,
      ...LOCATION_PARAMS,
      {
        name: "steps",
        type: "boolean",
        optional: true,
        description: "Include turn-by-turn steps (default false)",
      },
      {
        name: "lang",
        type: "string",
        optional: true,
        description:
          'BCP 47 language tag for step instructions (default "en"); "pt-BR" uses "pt", and the region sets the default units',
        enumValues: [
          { value: '"ar"' },
          { value: '"da"' },
          { value: '"de"' },
          { value: '"en"' },
          { value: '"es"' },
          { value: '"fi"' },
          { value: '"fr"' },
          { value: '"hi"' },
          { value: '"id"' },
          { value: '"it"' },
          { value: '"ja"' },
          { value: '"ko"' },
          { value: '"nb"' },
          { value: '"nl"' },
          { value: '"pl"' },
          { value: '"pt"' },
          { value: '"ru"' },
          { value: '"sv"' },
          { value: '"th"' },
          { value: '"tr"' },
          { value: '"vi"' },
          { value: '"zh"' },
        ],
      },
      {
        name: "units",
        type: '"km" | "mi"',
        optional: true,
        description:
          'Distance units in step instructions; defaults to "mi" for US, GB, LR and MM lang regions, otherwise "km"',
        enumValues: [{ value: '"km"' }, { value: '"mi"' }],
      },
      {
        name: "verbal",
        type: "boolean",
        optional: true,
        description:
          "Add spoken variants (verbal_alert, verbal_pre, verbal_post, verbal_succinct) to each step",
      },
      {
        name: "voice_instructions",
        type: "boolean",
        optional: true,
        description:
          "Add timed voice announcements (text and SSML) for the maneuver ending each step; needs steps: true",
      },
      {
        name: "banner_instructions",
        type: "boolean",
        optional: true,
        description:
          "Add banner instructions (road, ref, destinations, lanes) for the maneuver ending each step; needs steps: true",
      },
      {
        name: "roundabout_exits",
        type: "boolean",
        optional: true,
        description:
          "Give leaving a roundabout its own exit_roundabout step; needs steps: true",
      },
      {
        name: "voice_units",
        type: '"metric" | "imperial"',
        optional: true,
        description: "Distance units in voice announcements; defaults to units",
        enumValues: [{ value: '"metric"' }, { value: '"imperial"' }],
      },
      {
        name: "waypoint_names",
        type: "string[] | string",
        optional: true,
        description:
          'One name per point (origin, each waypoint, destination) for arrival instructions; "" keeps the default',
      },
      {
        name: "avoid_datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Keep out of the polygons of these datasets (up to 10 slugs or ids; not "plaza" or "all"): road segments touching one are left out of the graph.',
      },
      {
        name: "datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Also route over the roads of these datasets (up to 20 slugs or ids; not "plaza" or "all"): their line features with `highway` or `road_class`, joined to OSM roads where an end lies within 10 m of an OSM junction.',
      },
    ],
    returnType: "Route",
    description: "Compute a route between waypoints.",
  },
  isochrone: {
    name: "isochrone",
    params: [
      { name: "center", type: "Point", description: "Center point" },
      {
        name: "time",
        type: "number",
        optional: true,
        description: "Travel time in seconds",
      },
      {
        name: "distance",
        type: "number",
        optional: true,
        description: "Travel distance in meters",
      },
      {
        name: "mode",
        type: "string",
        optional: true,
        description: "Travel mode",
        enumValues: [...TRUCK_MODE_VALUES, TRANSIT_MODE_VALUE],
      },
      ...TRUCK_PARAMS,
      ...ACTIVE_PARAMS,
      {
        name: "depart_at",
        type: "string",
        optional: true,
        description:
          'Departure time for mode "transit" (ISO 8601 with an offset, local time at the feed without one, or "now"; default now)',
      },
      ...TRANSIT_PARAMS,
      ...SPEED_PARAMS,
      {
        name: "exclude",
        type: "string[]",
        optional: true,
        description:
          'Road types to leave out of the graph: "toll", "cash_only_tolls" (toll booths taking only cash), "ferry", "unpaved", "motorway", "trunk", "primary", "secondary", "tertiary"',
      },
      {
        name: "avoid_datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Keep out of the polygons of these datasets (up to 10 slugs or ids; not "plaza" or "all"): road segments touching one are left out of the graph.',
      },
      {
        name: "datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Also route over the roads of these datasets (up to 20 slugs or ids; not "plaza" or "all"): their line features with `highway` or `road_class`, joined to OSM roads where an end lies within 10 m of an OSM junction.',
      },
    ],
    returnType: "Isochrone",
    description: "Compute a travel-time or travel-distance polygon.",
  },
  geocode: {
    name: "geocode",
    params: [
      {
        name: "query",
        type: "string",
        optional: true,
        description:
          "Address or place name to geocode. Leave it out and pass structured components instead.",
      },
      {
        name: "address",
        type: "string",
        optional: true,
        description:
          'Structured: house number and street ("1600 Pennsylvania Ave" or "Rue de Rivoli 99")',
      },
      {
        name: "neighbourhood",
        type: "string",
        optional: true,
        description: "Structured: neighbourhood or suburb",
      },
      {
        name: "locality",
        type: "string",
        optional: true,
        description: "Structured: city, town or village",
      },
      {
        name: "county",
        type: "string",
        optional: true,
        description: "Structured: county or district",
      },
      {
        name: "region",
        type: "string",
        optional: true,
        description: "Structured: state, province or region",
      },
      {
        name: "postalcode",
        type: "string",
        optional: true,
        description: "Structured: postal or ZIP code",
      },
      {
        name: "country",
        type: "string",
        optional: true,
        description:
          'Structured: ISO 3166-1 alpha-2 code ("US") or country name',
      },
      {
        name: "focus",
        type: "Point",
        optional: true,
        description: "Bias results toward this point",
      },
      {
        name: "country_code",
        type: "string",
        optional: true,
        description: "ISO 3166-1 alpha-2 code to restrict results",
      },
      {
        name: "bbox",
        type: "Polygon",
        optional: true,
        description: "Restrict results to bbox(south, west, north, east)",
      },
      {
        name: "layers",
        type: "string | string[]",
        optional: true,
        description:
          'Only return these layers: "address" (addresses, streets, postal codes), "poi", "admin", "dataset" (features of the `datasets:` named), or single layers ("street", "postalcode", "neighbourhood", "locality", "county", "region", "country")',
        enumValues: GEOCODE_LAYER_VALUES,
      },
      {
        name: "boundary_gid",
        type: "string",
        optional: true,
        description:
          'Only return results inside this way or relation polygon, e.g. "osm:relation:62422"',
      },
      {
        name: "datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Also match features of these datasets (slugs or ids, "plaza" for every Plaza dataset, "all" for those plus yours). Matches carry layer "dataset" and the dataset slug.',
      },
      {
        name: "dataset_name_field",
        type: "string",
        optional: true,
        description:
          "Dataset property to match instead of the feature name (properties.name)",
      },
      {
        name: "limit",
        type: "number",
        optional: true,
        description: "Maximum number of results",
      },
    ],
    returnType: "PointSet",
    description:
      'Geocode an address to coordinates: free text, or structured components (address:, locality:, region:, postalcode:, ...). Results carry gid, layer, confidence, match_type and accuracy; when nothing matches, coarser layers are returned with match_type "fallback".',
  },
  // biome-ignore lint/style/useNamingConvention: PQL name
  place_lookup: {
    name: "place_lookup",
    params: [
      {
        name: "ids",
        type: "string | string[]",
        description:
          'Up to 50 Plaza GIDs, positional or as ids: [...], e.g. "osm:node:123", "osm:way:456", "osm:relation:789"',
      },
    ],
    returnType: "PointSet",
    description:
      "Look up places by GID (the gid of any geocoding result), with admin hierarchy and categories.",
  },
  // biome-ignore lint/style/useNamingConvention: PQL name
  reverse_geocode: {
    name: "reverse_geocode",
    params: [
      {
        name: "point",
        type: "Point",
        description: "Coordinates to reverse geocode",
      },
      {
        name: "include",
        type: '"census" | ["census"]',
        optional: true,
        description:
          'Extra data to attach. `"census"` adds a `census` object with Census GEOIDs (state, county, tract, block group, ZCTA, place, CBSA, congressional district) and their names.',
        enumValues: [
          {
            value: '"census"',
            description: "Census geographies (GEOIDs + names)",
          },
        ],
      },
      {
        name: "datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Datasets to look up at the point (slugs or ids, "plaza", "all"): each result gets a `datasets` list with the polygons containing the point and the nearest point or line feature within the radius.',
      },
    ],
    returnType: "PointSet",
    description: "Reverse geocode coordinates to an address.",
  },
  autocomplete: {
    name: "autocomplete",
    params: [
      {
        name: "query",
        type: "string",
        description: "Partial text to autocomplete",
      },
      {
        name: "center",
        type: "Point",
        optional: true,
        description: "Bias results toward this point",
      },
      {
        name: "layers",
        type: "string | string[]",
        optional: true,
        description:
          'Only return these layers: "address" (addresses, streets, postal codes), "poi", "admin", "dataset" (features of the `datasets:` named), or single layers ("street", "postalcode", "neighbourhood", "locality", "county", "region", "country")',
        enumValues: GEOCODE_LAYER_VALUES,
      },
      {
        name: "boundary_gid",
        type: "string",
        optional: true,
        description:
          'Only return results inside this way or relation polygon, e.g. "osm:relation:62422"',
      },
      {
        name: "datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Also match features of these datasets (slugs or ids, "plaza" for every Plaza dataset, "all" for those plus yours). Matches carry layer "dataset" and the dataset slug.',
      },
      {
        name: "dataset_name_field",
        type: "string",
        optional: true,
        description:
          "Dataset property to match instead of the feature name (properties.name)",
      },
    ],
    returnType: "PointSet",
    description: "Autocomplete a place name or address.",
  },
  // biome-ignore lint/style/useNamingConvention: PQL name
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
      { name: "origins", type: "Point[]", description: "Origin points" },
      {
        name: "destinations",
        type: "Point[]",
        description: "Destination points",
      },
      {
        name: "mode",
        type: "string",
        optional: true,
        description: "Travel mode",
        enumValues: TRUCK_MODE_VALUES,
      },
      ...TRUCK_PARAMS,
      ...ACTIVE_PARAMS,
      ...COSTING_PARAMS,
      {
        name: "exclude",
        type: "string[]",
        optional: true,
        description:
          'Road types to leave out of the graph: "toll", "cash_only_tolls" (toll booths taking only cash), "ferry", "unpaved", "motorway", "trunk", "primary", "secondary", "tertiary"',
      },
      {
        name: "avoid_datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Keep out of the polygons of these datasets (up to 10 slugs or ids; not "plaza" or "all"): road segments touching one are left out of the graph.',
      },
      {
        name: "datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Also route over the roads of these datasets (up to 20 slugs or ids; not "plaza" or "all"): their line features with `highway` or `road_class`, joined to OSM roads where an end lies within 10 m of an OSM junction.',
      },
    ],
    returnType: "Matrix",
    description: "Compute a distance/duration matrix between point sets.",
  },
  // biome-ignore lint/style/useNamingConvention: PQL name
  map_match: {
    name: "map_match",
    params: [
      { name: "points", type: "Point[]", description: "GPS trace points" },
      {
        name: "mode",
        type: "string",
        optional: true,
        description: "Travel mode",
        enumValues: TRUCK_MODE_VALUES,
      },
      ...TRUCK_PARAMS,
      ...ACTIVE_PARAMS,
      {
        name: "datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Also match to the roads of these datasets (up to 20 slugs or ids; not "plaza" or "all"): their line features with `highway` or `road_class`, joined to OSM roads where an end lies within 10 m of an OSM junction.',
      },
      {
        name: "exclude",
        type: "string[]",
        optional: true,
        description:
          'Road types the trace is never matched to: "toll", "cash_only_tolls" (toll booths taking only cash), "ferry", "unpaved", "motorway", "trunk", "primary", "secondary", "tertiary"',
      },
      {
        name: "avoid_datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Keep out of the polygons of these datasets (up to 10 slugs or ids; not "plaza" or "all"): roads touching one are never matched.',
      },
    ],
    returnType: "Route",
    description: "Snap a GPS trace to the road network.",
  },
  optimize: {
    name: "optimize",
    params: [
      {
        name: "waypoints",
        type: "Point[]",
        description: "Waypoints to optimize",
      },
      {
        name: "mode",
        type: "string",
        optional: true,
        description: "Travel mode",
        enumValues: TRUCK_MODE_VALUES,
      },
      ...TRUCK_PARAMS,
      ...ACTIVE_PARAMS,
      {
        name: "exclude",
        type: "string[]",
        optional: true,
        description:
          'Road types to leave out of the graph: "toll", "cash_only_tolls" (toll booths taking only cash), "ferry", "unpaved", "motorway", "trunk", "primary", "secondary", "tertiary"',
      },
      {
        name: "avoid_datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Keep out of the polygons of these datasets (up to 10 slugs or ids; not "plaza" or "all"): road segments touching one are left out of the graph.',
      },
    ],
    returnType: "Route",
    description: "Optimize waypoint ordering (TSP).",
  },
  // biome-ignore lint/style/useNamingConvention: PQL name
  ev_route: {
    name: "ev_route",
    params: [
      { name: "origin", type: "Point", description: "Starting point" },
      { name: "destination", type: "Point", description: "Ending point" },
      {
        name: "battery",
        type: "number",
        optional: true,
        description: "Battery capacity",
      },
      {
        name: "depart_at",
        type: "string",
        optional: true,
        description:
          'Departure time (ISO 8601, e.g. "2026-03-16T08:00:00Z", or "now") for time-of-day traffic',
      },
      {
        name: "traffic_model",
        type: '"best_guess" | "optimistic" | "pessimistic"',
        optional: true,
        description: "Traffic speed assumption; applies when depart_at is set",
        enumValues: [
          { value: '"best_guess"' },
          { value: '"optimistic"' },
          { value: '"pessimistic"' },
        ],
      },
      {
        name: "exclude",
        type: "string[]",
        optional: true,
        description:
          'Road types to avoid: "toll", "cash_only_tolls" (toll booths taking only cash), "ferry", "unpaved", "motorway", "trunk", "primary", "secondary", "tertiary"',
      },
      ...COSTING_PARAMS,
      {
        name: "steps",
        type: "boolean",
        optional: true,
        description: "Include turn-by-turn steps (default false)",
      },
      {
        name: "lang",
        type: "string",
        optional: true,
        description:
          'BCP 47 language tag for step instructions (default "en"); "pt-BR" uses "pt", and the region sets the default units',
        enumValues: [
          { value: '"ar"' },
          { value: '"da"' },
          { value: '"de"' },
          { value: '"en"' },
          { value: '"es"' },
          { value: '"fi"' },
          { value: '"fr"' },
          { value: '"hi"' },
          { value: '"id"' },
          { value: '"it"' },
          { value: '"ja"' },
          { value: '"ko"' },
          { value: '"nb"' },
          { value: '"nl"' },
          { value: '"pl"' },
          { value: '"pt"' },
          { value: '"ru"' },
          { value: '"sv"' },
          { value: '"th"' },
          { value: '"tr"' },
          { value: '"vi"' },
          { value: '"zh"' },
        ],
      },
      {
        name: "units",
        type: '"km" | "mi"',
        optional: true,
        description:
          'Distance units in step instructions; defaults to "mi" for US, GB, LR and MM lang regions, otherwise "km"',
        enumValues: [{ value: '"km"' }, { value: '"mi"' }],
      },
      {
        name: "verbal",
        type: "boolean",
        optional: true,
        description:
          "Add spoken variants (verbal_alert, verbal_pre, verbal_post, verbal_succinct) to each step",
      },
      {
        name: "voice_instructions",
        type: "boolean",
        optional: true,
        description:
          "Add timed voice announcements (text and SSML) for the maneuver ending each step; needs steps: true",
      },
      {
        name: "banner_instructions",
        type: "boolean",
        optional: true,
        description:
          "Add banner instructions (road, ref, destinations, lanes) for the maneuver ending each step; needs steps: true",
      },
      {
        name: "roundabout_exits",
        type: "boolean",
        optional: true,
        description:
          "Give leaving a roundabout its own exit_roundabout step; needs steps: true",
      },
      {
        name: "voice_units",
        type: '"metric" | "imperial"',
        optional: true,
        description: "Distance units in voice announcements; defaults to units",
        enumValues: [{ value: '"metric"' }, { value: '"imperial"' }],
      },
      {
        name: "waypoint_names",
        type: "string[] | string",
        optional: true,
        description:
          'One name per point (origin, each waypoint, destination) for arrival instructions; "" keeps the default',
      },
      {
        name: "avoid_datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Keep out of the polygons of these datasets (up to 10 slugs or ids; not "plaza" or "all"): road segments touching one are left out of the graph.',
      },
      {
        name: "datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Also route over the roads of these datasets (up to 20 slugs or ids; not "plaza" or "all"): their line features with `highway` or `road_class`, joined to OSM roads where an end lies within 10 m of an OSM junction.',
      },
    ],
    returnType: "Route",
    description: "Compute an EV-optimized route with charging stops.",
  },
  elevation: {
    name: "elevation",
    params: [
      {
        name: "point",
        type: "Point",
        description: "Point to get elevation for",
      },
      {
        name: "points",
        type: "Point[]",
        optional: true,
        description: "Several points to look up at once (instead of point)",
      },
    ],
    returnType: "Elevation",
    description: "Get elevation at a point.",
  },
  // biome-ignore lint/style/useNamingConvention: PQL name
  elevation_profile: {
    name: "elevation_profile",
    params: [
      {
        name: "line",
        type: "LineString | Route",
        description: "Line to profile",
      },
    ],
    returnType: "Elevation",
    description: "Get elevation profile along a line.",
  },
  nearest: {
    name: "nearest",
    params: [
      { name: "point", type: "Point", description: "Reference point" },
      {
        name: "type",
        type: "string",
        optional: true,
        description: "Element type",
      },
    ],
    returnType: "PointSet",
    description: "Find nearest OSM features to a point.",
  },
  centroid: {
    name: "centroid",
    params: [
      {
        name: "locations",
        type: "Point[]",
        description: "2 to 50 places people are coming from",
      },
      {
        name: "mode",
        type: "string",
        optional: true,
        description: "Travel mode",
        enumValues: TRUCK_MODE_VALUES,
      },
      ...TRUCK_PARAMS,
      ...ACTIVE_PARAMS,
      {
        name: "metric",
        type: '"time" | "distance"',
        optional: true,
        description: "Total travel cost to minimise (default time)",
        enumValues: [{ value: '"time"' }, { value: '"distance"' }],
      },
      {
        name: "exclude",
        type: "string[]",
        optional: true,
        description:
          'Road types to avoid: "toll", "cash_only_tolls" (toll booths taking only cash), "ferry", "unpaved", "motorway", "trunk", "primary", "secondary", "tertiary"',
      },
      {
        name: "avoid_datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Keep out of the polygons of these datasets (up to 10 slugs or ids; not "plaza" or "all"): road segments touching one are left out of the graph.',
      },
    ],
    returnType: "PointSet",
    description:
      "Find the meeting point on the road network with the least total travel cost from every location.",
  },
  expansion: {
    name: "expansion",
    params: [
      {
        name: "action",
        type: '"route" | "isochrone" | "matrix"',
        description:
          "Search to expand; pass that computation's own keywords (origin/destination, center/time, origins/destinations)",
        enumValues: [
          { value: '"route"' },
          { value: '"isochrone"' },
          { value: '"matrix"' },
        ],
      },
      {
        name: "origin",
        type: "Point",
        optional: true,
        description: "Route start (route)",
      },
      {
        name: "destination",
        type: "Point",
        optional: true,
        description: "Route end (route)",
      },
      {
        name: "center",
        type: "Point",
        optional: true,
        description: "Isochrone center (isochrone)",
      },
      {
        name: "time",
        type: "number | number[]",
        optional: true,
        description: "Isochrone time budget(s) in seconds (isochrone)",
      },
      {
        name: "origins",
        type: "Point[]",
        optional: true,
        description: "Matrix origins (matrix)",
      },
      {
        name: "destinations",
        type: "Point[]",
        optional: true,
        description: "Matrix destinations (matrix)",
      },
      {
        name: "mode",
        type: "string",
        optional: true,
        description: "Travel mode",
        enumValues: TRUCK_MODE_VALUES,
      },
      ...TRUCK_PARAMS,
      ...ACTIVE_PARAMS,
      {
        name: "exclude",
        type: "string[]",
        optional: true,
        description:
          'Road types to avoid (route, matrix): "toll", "cash_only_tolls" (toll booths taking only cash), "ferry", "unpaved", "motorway", "trunk", "primary", "secondary", "tertiary"',
      },
      {
        name: "expansion_properties",
        type: "string[]",
        optional: true,
        description:
          'Per-edge properties: "duration" (default), "distance", "cost", "cumulative_cost", "edge_id", "osm_way_id"',
      },
      {
        name: "avoid_datasets",
        type: "string | string[]",
        optional: true,
        description:
          'Keep out of the polygons of these datasets (up to 10 slugs or ids; not "plaza" or "all"): road segments touching one are left out of the graph.',
      },
    ],
    returnType: "LineSet",
    description:
      "Debug: the road edges the router visited for a route, isochrone or matrix, with the path marked on_path. Needs the X-Plaza-Debug header or an admin key.",
  },
}

/** Values accepted by `reverse_geocode(include: ...)`. */
export const REVERSE_GEOCODE_INCLUDES = ["census"]

const ROUTE_KWARGS = [
  "origin",
  "destination",
  "mode",
  "steps",
  "alternatives",
  "waypoints",
  "depart_at",
  "traffic_model",
  "exclude",
  "overview",
  "geometries",
  "annotations",
  "lang",
  "units",
  "verbal",
  "avoid_datasets",
  "datasets",
  "voice_instructions",
  "banner_instructions",
  "roundabout_exits",
  "voice_units",
  "waypoint_names",
]
const GEOCODE_FILTER_KWARGS = [
  "focus",
  "country_code",
  "bbox",
  "layers",
  "layer",
  "boundary_gid",
  "limit",
  "lang",
  "datasets",
  "dataset_name_field",
]

/**
 * Keywords each computation accepts: the parameters of the REST endpoint it
 * stands in for. Mirrors `@computation_kwargs` in lib/plazaql/type_checker.ex.
 */
const TRUCK_OPTION_KWARGS = [
  "height",
  "width",
  "length",
  "weight",
  "axle_load",
  "axle_count",
  "hazmat",
]

export const COMPUTATION_KWARGS: Record<string, string[]> = {
  route: [
    ...ROUTE_KWARGS,
    ...TRUCK_OPTION_KWARGS,
    ...TRANSIT_OPTIONS,
    ...ACTIVE_OPTIONS,
    ...COSTING_OPTIONS,
    ...LOCATION_OPTIONS,
    "recostings",
  ],
  ev_route: [
    ...ROUTE_KWARGS,
    ...COSTING_OPTIONS,
    "battery",
    "battery_capacity_wh",
    "initial_charge_pct",
    "min_charge_pct",
    "connector_types",
    "min_power_kw",
  ],
  isochrone: [
    "center",
    "time",
    "mode",
    "denoise",
    "generalize",
    "exclude",
    "avoid_datasets",
    "datasets",
    "depart_at",
    ...TRUCK_OPTION_KWARGS,
    ...TRANSIT_OPTIONS,
    ...ACTIVE_OPTIONS,
    ...COSTING_SPEEDS,
  ],
  geocode: [
    "query",
    "addresses",
    "address",
    "neighbourhood",
    "locality",
    "county",
    "region",
    "postalcode",
    "country",
    ...GEOCODE_FILTER_KWARGS,
  ],
  autocomplete: ["query", ...GEOCODE_FILTER_KWARGS],
  text_search: ["query", "limit", "bbox", "focus"],
  reverse_geocode: [
    "point",
    "radius",
    "limit",
    "include",
    "layer",
    "lang",
    "datasets",
  ],
  nearest: ["point", "radius"],
  matrix: [
    "origins",
    "destinations",
    "mode",
    "annotations",
    "fallback_speed",
    "exclude",
    "avoid_datasets",
    "datasets",
    ...TRUCK_OPTION_KWARGS,
    ...ACTIVE_OPTIONS,
    ...COSTING_OPTIONS,
  ],
  map_match: [
    "points",
    "mode",
    "radiuses",
    "exclude",
    "datasets",
    "avoid_datasets",
    ...TRUCK_OPTION_KWARGS,
    ...ACTIVE_OPTIONS,
  ],
  optimize: [
    "waypoints",
    "mode",
    "roundtrip",
    "exclude",
    "avoid_datasets",
    ...TRUCK_OPTION_KWARGS,
    ...ACTIVE_OPTIONS,
  ],
  elevation: ["point", "points"],
  elevation_profile: ["points"],
  centroid: [
    "locations",
    "mode",
    "metric",
    "exclude",
    "avoid_datasets",
    ...TRUCK_OPTION_KWARGS,
    ...ACTIVE_OPTIONS,
  ],
  expansion: [
    "action",
    "origin",
    "destination",
    "center",
    "time",
    "origins",
    "destinations",
    "mode",
    "exclude",
    "expansion_properties",
    "avoid_datasets",
    ...TRUCK_OPTION_KWARGS,
    ...ACTIVE_OPTIONS,
  ],
  place_lookup: ["ids"],
}

/** Values accepted by `centroid(metric: ...)`. */
export const CENTROID_METRICS = ["time", "distance"]

/** Values accepted by `expansion(action: ...)`. */
export const EXPANSION_ACTIONS = ["route", "isochrone", "matrix"]

/** Values accepted by `expansion(expansion_properties: [...])`. */
export const EXPANSION_PROPERTIES = [
  "duration",
  "distance",
  "cost",
  "cumulative_cost",
  "edge_id",
  "osm_way_id",
]

/**
 * Expression-only functions (valid inside `.filter()`, `.sort()`, `.sum()`,
 * `.group_by()` etc., not as top-level statements).
 */
export const EXPRESSION_FUNCTIONS: Record<string, FunctionSignature> = {
  // biome-ignore lint/style/useNamingConvention: PQL name
  overlap_fraction: {
    name: "overlap_fraction",
    params: [
      {
        name: "geometry",
        type: "Polygon | Bbox | $var | $$.name",
        description:
          "Reference polygon: polygon(...), bbox(s, w, n, e), or a variable holding polygons",
      },
    ],
    returnType: "number",
    description:
      'Fraction (0..1) of each feature\'s area that lies inside the reference polygon — for area-weighted apportionment, e.g. `.sum(number(t["population"]) * overlap_fraction($area))`.',
  },
}

export const METHOD_PARAM_VALUES: Record<
  string,
  Record<string, Array<{ value: string; description?: string }>>
> = {
  sort: {
    order: [
      { value: ":asc", description: "Ascending order" },
      { value: ":desc", description: "Descending order" },
    ],
  },
  expand: {
    direction: [
      {
        value: ":down",
        description: "Expand relations to members / ways to nodes",
      },
      {
        value: ":up",
        description: "Expand nodes to parent ways / ways to parent relations",
      },
    ],
  },
}
