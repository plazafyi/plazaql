// PlazaQL type checker — ported from Plaza.PlazaQL.TypeChecker

import type {
  Arg,
  ChainNode,
  Expr,
  KwArg,
  MethodGroup,
  MethodNode,
  Pos,
  PosArg,
  PqlType,
  Statement,
  TagFilter,
} from "./types.js"
import {
  ACTIVE_COMPUTATIONS,
  ACTIVE_OPTIONS,
  ACTIVE_RANGES,
  BICYCLE_MODES,
  BICYCLE_OPTIONS,
  BICYCLE_TYPES,
  CENTROID_METRICS,
  COMPUTATION_KWARGS,
  COSTING_PENALTIES,
  COSTING_PREFERENCES,
  computationType,
  EXPANSION_ACTIONS,
  EXPANSION_PROPERTIES,
  FOOT_MODES,
  GEOCODE_LAYERS,
  isOutputMode,
  LOCATION_OPTIONS,
  MOTOR_SCOOTER_MODES,
  MOTOR_SCOOTER_OPTIONS,
  MOTORCYCLE_MODES,
  MOTORCYCLE_OPTIONS,
  MOTORCYCLE_STYLES,
  methodCategory,
  methodGroup,
  methodOutputType,
  methodPhase,
  PEDESTRIAN_OPTIONS,
  REVERSE_GEOCODE_INCLUDES,
  STRUCTURED_GEOCODE_COMPONENTS,
  searchBaseType,
  TRANSIT_ACTIVE_OPTIONS,
  TRANSIT_COMPUTATIONS,
  TRANSIT_OPTIONS,
  TRANSIT_PREFERENCES,
  TRUCK_DIMENSIONS,
  TRUCK_OPTION_COMPUTATION_NAMES,
  TRUCK_OPTION_COMPUTATIONS,
  TRUCK_OPTIONS,
  unionType,
  VEHICLE_COMPUTATION_NAMES,
  validSpatialArgTypes,
} from "./types.js"

// ── Diagnostic ───────────────────────────────────────────────────────

export interface TypeCheckError {
  line: number
  col: number
  message: string
  hint?: string
  severity: "error" | "warning"
}

// ── Scope ────────────────────────────────────────────────────────────

export interface VarInfo {
  type: PqlType
  line: number
  col: number
  expr: Expr
}

export type Scope = Map<string, VarInfo>

// ── Public API ───────────────────────────────────────────────────────

export interface TypeCheckResult {
  errors: TypeCheckError[]
  scope: Scope
  /** Type of each statement's expression (indexed by statement index) */
  stmtTypes: (PqlType | null)[]
}

export function typeCheck(ast: Statement[]): TypeCheckResult {
  const scope: Scope = new Map()
  const outputScope: Scope = new Map() // tracks $$.name outputs
  const errors: TypeCheckError[] = []
  const stmtTypes: (PqlType | null)[] = []

  for (const stmt of ast) {
    const { errs, type } = checkStatement(stmt, scope, outputScope)
    errors.push(...errs)
    stmtTypes.push(type)
  }

  // Check for at least one output
  const outputStmts = ast.filter((s) => s.kind === "output")
  const bareStmts = ast.filter((s) => s.kind === "bare_output")
  const hasOutput = outputStmts.length > 0 || bareStmts.length > 0
  const hasNonSettings = ast.some((s) => s.kind !== "settings")
  if (!hasOutput && hasNonSettings) {
    errors.push({
      line: 1,
      col: 1,
      message: "at least one output statement is required",
      hint: 'add an expression like `search(amenity: "cafe");` or `$$ = <expression>;`',
      severity: "error",
    })
  }

  // Check: only one simple output allowed (bare or $$ =)
  const simpleOutputs = [
    ...outputStmts.filter((s) => s.kind === "output" && s.name === null),
    ...bareStmts,
  ]
  if (simpleOutputs.length > 1) {
    for (const s of simpleOutputs.slice(1)) {
      errors.push({
        line: s.pos.line,
        col: s.pos.col,
        message: "only one simple output is allowed per query",
        hint: "use named outputs (`$$.name = ...`) for multiple results",
        severity: "error",
      })
    }
  }

  // Check: cannot mix simple output and named $$.name =
  const namedOutputs = outputStmts.filter(
    (s) => s.kind === "output" && s.name !== null,
  )
  if (simpleOutputs.length > 0 && namedOutputs.length > 0) {
    const conflicting = namedOutputs[0] as (typeof namedOutputs)[0]
    errors.push({
      line: conflicting.pos.line,
      col: conflicting.pos.col,
      message: "cannot mix simple output and named `$$.name` outputs",
      hint: "use either bare expressions or `$$ = ...` for single output, or `$$.name = ...` for multiple named outputs",
      severity: "error",
    })
  }

  errors.sort((a, b) => a.line - b.line || a.col - b.col)
  return { errors, scope, stmtTypes }
}

// ── Statement checking ───────────────────────────────────────────────

function checkStatement(
  stmt: Statement,
  scope: Scope,
  outputScope: Scope,
): { errs: TypeCheckError[]; type: PqlType | null } {
  switch (stmt.kind) {
    case "settings":
      return { errs: [], type: null }

    case "var_assign": {
      const errs: TypeCheckError[] = []
      if (scope.has(stmt.name)) {
        errs.push({
          line: stmt.pos.line,
          col: stmt.pos.col,
          message: `duplicate variable \`${stmt.name}\``,
          hint: "choose a different name or remove the earlier definition",
          severity: "error",
        })
      }
      const { type, errors: exprErrs } = checkExpr(
        stmt.expr,
        scope,
        outputScope,
      )
      errs.push(...exprErrs)
      scope.set(stmt.name, {
        type,
        line: stmt.pos.line,
        col: stmt.pos.col,
        expr: stmt.expr,
      })
      return { errs, type }
    }

    case "bare_output": {
      const { type, errors: exprErrs } = checkExpr(
        stmt.expr,
        scope,
        outputScope,
      )
      return { errs: exprErrs, type }
    }

    case "output": {
      const { type, errors: exprErrs } = checkExpr(
        stmt.expr,
        scope,
        outputScope,
      )
      const errs = [...exprErrs]
      // Register named output in outputScope for later $$.name references
      if (stmt.name !== null) {
        const key = `$$.${stmt.name}`
        if (outputScope.has(key)) {
          errs.push({
            line: stmt.pos.line,
            col: stmt.pos.col,
            message: `duplicate output variable \`${key}\``,
            hint: "choose a different name or remove the earlier definition",
            severity: "error",
          })
        }
        outputScope.set(key, {
          type,
          line: stmt.pos.line,
          col: stmt.pos.col,
          expr: stmt.expr,
        })
      }
      return { errs, type }
    }
  }
}

// ── Expression type checking ─────────────────────────────────────────

interface ExprResult {
  type: PqlType
  errors: TypeCheckError[]
}

function checkExpr(expr: Expr, scope: Scope, outputScope: Scope): ExprResult {
  switch (expr.kind) {
    case "search": {
      const baseType = searchBaseType(expr.elementType)
      const { finalType, errors } = checkMethodChain(
        expr.methods,
        baseType,
        scope,
        outputScope,
      )
      return { type: finalType, errors }
    }

    case "boundary":
      return { type: "Boundary", errors: [] }

    case "computation": {
      const type = computationType(expr.name)
      const argErrors = checkVarRefsInArgs(expr.args, scope, outputScope)
      const kwargErrors = [
        ...checkComputationKwargs(expr.name, expr.args, expr.pos),
        ...checkTruckKwargs(expr.name, expr.args, expr.pos),
        ...checkTransitKwargs(expr.name, expr.args, expr.pos),
        ...checkActiveKwargs(expr.name, expr.args, expr.pos),
        ...checkDatasetKwargs(expr.args, expr.pos),
        ...checkIsochroneBudget(expr.name, expr.args, expr.pos),
      ]
      return { type, errors: [...argErrors, ...kwargErrors] }
    }

    case "overlap_fraction":
      return {
        type: "Scalar",
        errors: checkOverlapFractionArg(
          expr.arg,
          expr.pos,
          scope,
          outputScope,
          true,
        ),
      }

    case "expression":
      return {
        type: "Scalar",
        errors: expr.calls.flatMap(
          (call) => checkExpr(call, scope, outputScope).errors,
        ),
      }

    case "point":
      return { type: "Point", errors: [] }

    case "bbox":
      return { type: "Polygon", errors: [] }

    case "linestring":
    case "polygon":
    case "circle":
      return {
        type: expr.kind === "linestring" ? "LineString" : "Polygon",
        errors: [],
      }

    case "var_ref": {
      const info = scope.get(expr.name)
      if (!info) {
        return {
          type: "GeoSet",
          errors: [
            {
              line: expr.pos.line,
              col: expr.pos.col,
              message: `undefined variable \`${expr.name}\``,
              hint: `define it first: ${expr.name} = <expression>;`,
              severity: "error",
            },
          ],
        }
      }
      return { type: info.type, errors: [] }
    }

    case "output_ref": {
      const key = `$$.${expr.name}`
      const info = outputScope.get(key)
      if (!info) {
        return {
          type: "GeoSet",
          errors: [
            {
              line: expr.pos.line,
              col: expr.pos.col,
              message: `undefined output variable \`${key}\``,
              hint: `assign it first: ${key} = <expression>;`,
              severity: "error",
            },
          ],
        }
      }
      return { type: info.type, errors: [] }
    }

    case "chain": {
      return checkChain(expr, scope, outputScope)
    }

    case "union": {
      const leftR = checkExpr(expr.left, scope, outputScope)
      const rightR = checkExpr(expr.right, scope, outputScope)
      const resultType = unionType(leftR.type, rightR.type)
      return {
        type: resultType,
        errors: [...leftR.errors, ...rightR.errors],
      }
    }

    case "difference": {
      const leftR = checkExpr(expr.left, scope, outputScope)
      const rightR = checkExpr(expr.right, scope, outputScope)
      return {
        type: leftR.type,
        errors: [...leftR.errors, ...rightR.errors],
      }
    }

    case "list": {
      const itemErrors = expr.items.flatMap(
        (item) => checkExpr(item, scope, outputScope).errors,
      )
      return { type: "Scalar", errors: itemErrors }
    }

    case "number":
    case "string":
    case "identifier":
    case "atom":
    case "bool":
      return { type: "Scalar", errors: [] }

    default:
      return { type: "Scalar", errors: [] }
  }
}

// ── Chain flattening & checking ──────────────────────────────────────

function checkChain(
  chain: ChainNode,
  scope: Scope,
  outputScope: Scope,
): ExprResult {
  const { base, methods } = flattenChain(chain)
  const baseResult = checkExpr(base, scope, outputScope)
  const { finalType, errors: methodErrors } = checkMethodChain(
    methods,
    baseResult.type,
    scope,
    outputScope,
  )
  return {
    type: finalType,
    errors: [...baseResult.errors, ...methodErrors],
  }
}

function flattenChain(node: Expr): { base: Expr; methods: MethodNode[] } {
  const methods: MethodNode[] = []
  let current = node
  while (current.kind === "chain") {
    methods.unshift((current as ChainNode).method)
    current = (current as ChainNode).receiver
  }
  return { base: current, methods }
}

// ── Method chain validation ──────────────────────────────────────────

const GROUP_RANK: Record<MethodGroup, number> = {
  source: 0,
  // biome-ignore lint/style/useNamingConvention: matches PQL group name
  freely_orderable: 1,
  // biome-ignore lint/style/useNamingConvention: matches PQL group name
  late_chain: 2,
  terminal: 3,
}

interface ChainContext {
  lastGroup: MethodGroup
  lastMethodName: string | null
  hasAround: boolean
  hasLimit: boolean
  hasOffset: boolean
  hasCursor: boolean
  outputModeCount: number
  currentType: PqlType
}

function checkMethodChain(
  methods: MethodNode[],
  baseType: PqlType,
  scope: Scope,
  outputScope: Scope,
): { finalType: PqlType; errors: TypeCheckError[] } {
  const ctx: ChainContext = {
    lastGroup: "source" as MethodGroup,
    lastMethodName: null,
    hasAround: false,
    hasLimit: false,
    hasOffset: false,
    hasCursor: false,
    outputModeCount: 0,
    currentType: baseType,
  }

  const errors: TypeCheckError[] = []

  for (const method of methods) {
    const methodErrs = checkMethod(method, ctx, scope, outputScope)
    errors.push(...methodErrs)
  }

  return { finalType: ctx.currentType, errors }
}

function checkMethod(
  method: MethodNode,
  ctx: ChainContext,
  scope: Scope,
  outputScope: Scope,
): TypeCheckError[] {
  const group = methodGroup(method.name)
  const category = methodCategory(method.name)
  const errors: TypeCheckError[] = []

  // 1. Group ordering
  if (ctx.lastGroup === "terminal") {
    errors.push({
      line: method.pos.line,
      col: method.pos.col,
      message: `\`.${method.name}()\` cannot follow \`.${ctx.lastMethodName}()\` — output modes must be last in the chain`,
      hint: `move \`.${method.name}()\` before the output mode`,
      severity: "error",
    })
  } else if (group === "freely_orderable" && ctx.lastGroup === "late_chain") {
    errors.push({
      line: method.pos.line,
      col: method.pos.col,
      message: `\`.${method.name}()\` (${category}) cannot follow \`.${ctx.lastMethodName}()\` (ordering) — ordering methods must come after all other methods`,
      hint: `move \`.${method.name}()\` before \`.${ctx.lastMethodName}()\``,
      severity: "error",
    })
  }

  // 2. Output mode exclusivity
  if (isOutputMode(method.name) && ctx.outputModeCount > 0) {
    errors.push({
      line: method.pos.line,
      col: method.pos.col,
      message: `multiple output modes — \`.${method.name}()\` conflicts with earlier output mode`,
      hint: "use only one output mode per chain (`.count()`, `.ids()`, `.tags()`, or `.skel()`)",
      severity: "error",
    })
  }

  // 3. Method-type compatibility
  const compat = methodOutputType(method.name, ctx.currentType)
  if (compat.ok) {
    ctx.currentType = compat.type
  } else {
    errors.push({
      line: method.pos.line,
      col: method.pos.col,
      message: compat.error,
      hint: simplifyHint(method.name, ctx.currentType),
      severity: "error",
    })
  }

  // 4. Spatial arg type checking
  errors.push(
    ...checkSpatialArgs(
      method.name,
      method.args,
      method.pos,
      scope,
      outputScope,
    ),
  )

  // 5. Var refs in args (only for Arg[], not TagFilter[])
  if (isArgArray(method.args)) {
    errors.push(...checkVarRefsInArgs(method.args, scope, outputScope))
    errors.push(...checkExpressionArgs(method.args, scope, outputScope))
    if (method.name === "overlap_fraction") {
      errors.push(
        ...checkOverlapFractionMethod(
          method.args,
          method.pos,
          scope,
          outputScope,
        ),
      )
    }
  }

  // 6. Contextual requirements
  errors.push(...checkContextual(method.name, method.args, ctx, method.pos))

  // Update context
  if (GROUP_RANK[group] > GROUP_RANK[ctx.lastGroup]) {
    ctx.lastGroup = group
  }
  ctx.lastMethodName = method.name
  recordMethod(ctx, method.name)

  return errors
}

// The chain facts later methods check (`.offset()` needs `.limit()`, ...).
function recordMethod(ctx: ChainContext, name: string): void {
  ctx.hasAround ||= name === "around"
  ctx.hasLimit ||= name === "limit"
  ctx.hasOffset ||= name === "offset"
  ctx.hasCursor ||= name === "cursor"
  if (isOutputMode(name)) {
    ctx.outputModeCount++
  }
}

// ── Method compatibility hints ───────────────────────────────────────

function simplifyHint(
  _method: string,
  _inputType: PqlType,
): string | undefined {
  return undefined
}

// ── Spatial argument checking ────────────────────────────────────────

const SPATIAL_WITH_GEOMETRY = new Set([
  "within",
  "not_within",
  "around",
  "intersects",
  "not_intersects",
  "contains",
  "not_contains",
  "crosses",
  "touches",
])

function checkSpatialArgs(
  methodName: string,
  args: Arg[] | TagFilter[],
  pos: Pos,
  scope: Scope,
  outputScope: Scope,
): TypeCheckError[] {
  if (!SPATIAL_WITH_GEOMETRY.has(methodName)) {
    return []
  }
  if (!isArgArray(args)) {
    return []
  }

  const validTypes = validSpatialArgTypes(methodName)
  const errors: TypeCheckError[] = []

  // `.around(distance, geometry)`: the first positional argument is the
  // distance (a number or a number variable), never the geometry.
  const geometryArgs =
    methodName === "around" && args[0]?.type === "posarg" ? args.slice(1) : args

  for (const expr of extractGeometryExprs(geometryArgs)) {
    const argType = inferArgType(expr, scope, outputScope)
    if (argType !== null && !validTypes.includes(argType)) {
      errors.push({
        line: pos.line,
        col: pos.col,
        message: `\`.${methodName}()\` requires ${validTypes.join(", ")} but got ${argType}`,
        hint: spatialHint(methodName, argType),
        severity: "error",
      })
    }
  }

  return errors
}

function extractGeometryExprs(args: Arg[]): Expr[] {
  const exprs: Expr[] = []
  for (const arg of args) {
    if (arg.type === "kwarg" && arg.name === "geometry") {
      exprs.push(arg.value)
    } else if (arg.type === "posarg") {
      const v = arg.value
      if (
        v.kind !== "number" &&
        v.kind !== "string" &&
        v.kind !== "identifier" &&
        v.kind !== "atom" &&
        v.kind !== "bool"
      ) {
        exprs.push(v)
      }
    }
  }
  return exprs
}

const ARG_TYPE_BY_KIND: Partial<Record<Expr["kind"], PqlType>> = {
  point: "Point",
  linestring: "LineString",
  polygon: "Polygon",
  bbox: "Polygon",
  circle: "Polygon",
  boundary: "Boundary",
}

function inferArgType(
  expr: Expr,
  scope: Scope,
  outputScope: Scope,
): PqlType | null {
  if (expr.kind === "var_ref") {
    const info = scope.get(expr.name)
    return info?.type ?? null
  }
  if (expr.kind === "output_ref") {
    const info = outputScope.get(`$$.${expr.name}`)
    return info?.type ?? null
  }
  if (expr.kind === "computation") {
    return computationType(expr.name)
  }
  return ARG_TYPE_BY_KIND[expr.kind] ?? null
}

function spatialHint(method: string, argType: PqlType): string | undefined {
  if (method === "within" && argType === "Route") {
    return "use `.around(distance: 200, geometry: $var)` to search near the route"
  }
  if (method === "within") {
    return "use a `boundary()`, `polygon()`, or `isochrone()` variable"
  }
  if (method === "crosses") {
    return "`.crosses()` requires a LineString or Route geometry"
  }
  return undefined
}

// ── Var ref checking in args ─────────────────────────────────────────

function checkVarRefsInArgs(
  args: Arg[],
  scope: Scope,
  outputScope: Scope,
): TypeCheckError[] {
  const errors: TypeCheckError[] = []
  for (const arg of args) {
    const expr = arg.value
    if (expr.kind === "var_ref" && !scope.has(expr.name)) {
      errors.push({
        line: expr.pos.line,
        col: expr.pos.col,
        message: `undefined variable \`${expr.name}\``,
        hint: `define it first: ${expr.name} = <expression>;`,
        severity: "error",
      })
    }
    if (expr.kind === "output_ref") {
      const key = `$$.${expr.name}`
      if (!outputScope.has(key)) {
        errors.push({
          line: expr.pos.line,
          col: expr.pos.col,
          message: `undefined output variable \`${key}\``,
          hint: `assign it first: ${key} = <expression>;`,
          severity: "error",
        })
      }
    }
  }
  return errors
}

// ── Expression arguments (overlap_fraction) ─────────────────────────

function checkExpressionArgs(
  args: Arg[],
  scope: Scope,
  outputScope: Scope,
): TypeCheckError[] {
  return args.flatMap((arg) =>
    arg.value.kind === "overlap_fraction" || arg.value.kind === "expression"
      ? checkExpr(arg.value, scope, outputScope).errors
      : [],
  )
}

const OVERLAP_FRACTION_MESSAGE =
  "`overlap_fraction()` expects a polygon(...), bbox(...), or a variable holding polygons"
const OVERLAP_FRACTION_HINT =
  "pass `polygon(point(lat, lng), ...)`, `bbox(s, w, n, e)`, `$var`, or `$$.name`"

// Variable types that cannot hold polygons
const NON_POLYGONAL_TYPES: PqlType[] = [
  "Point",
  "LineString",
  "PointSet",
  "LineSet",
  "Route",
  "Matrix",
  "Elevation",
  "Scalar",
  "GroupedSet",
]

function overlapError(pos: Pos, message = OVERLAP_FRACTION_MESSAGE) {
  return {
    line: pos.line,
    col: pos.col,
    message,
    hint: OVERLAP_FRACTION_HINT,
    severity: "error" as const,
  }
}

function checkOverlapRefType(
  name: string,
  type: PqlType,
  pos: Pos,
): TypeCheckError[] {
  if (NON_POLYGONAL_TYPES.includes(type)) {
    return [
      overlapError(
        pos,
        `${OVERLAP_FRACTION_MESSAGE}, but \`${name}\` is ${type}`,
      ),
    ]
  }
  return []
}

function isLiteralPolygon(arg: Expr): boolean {
  if (arg.kind === "bbox") {
    return arg.s !== null && arg.w !== null && arg.n !== null && arg.e !== null
  }
  if (arg.kind !== "polygon") {
    return false
  }
  const coords = new Set<string>()
  for (const item of arg.items) {
    if (item.kind !== "point" || item.lat === null || item.lng === null) {
      return false
    }
    coords.add(`${item.lat},${item.lng}`)
  }
  return coords.size >= 3
}

function checkOverlapFractionArg(
  arg: Expr | null,
  pos: Pos,
  scope: Scope,
  outputScope: Scope,
  reportUndefined: boolean,
): TypeCheckError[] {
  if (arg === null) {
    return [overlapError(pos)]
  }
  if (isLiteralPolygon(arg)) {
    return []
  }
  if (arg.kind === "var_ref") {
    const info = scope.get(arg.name)
    if (info) {
      return checkOverlapRefType(arg.name, info.type, pos)
    }
    return reportUndefined
      ? checkVarRefsInArgs([{ type: "posarg", value: arg }], scope, outputScope)
      : []
  }
  if (arg.kind === "output_ref" && arg.name !== "") {
    const key = `$$.${arg.name}`
    const info = outputScope.get(key)
    if (info) {
      return checkOverlapRefType(key, info.type, pos)
    }
    return reportUndefined
      ? checkVarRefsInArgs([{ type: "posarg", value: arg }], scope, outputScope)
      : []
  }
  return [overlapError(pos)]
}

function checkOverlapFractionMethod(
  args: Arg[],
  pos: Pos,
  scope: Scope,
  outputScope: Scope,
): TypeCheckError[] {
  const [first] = args
  if (args.length !== 1 || first?.type !== "posarg") {
    return [
      overlapError(
        pos,
        "`.overlap_fraction()` takes exactly one geometry argument",
      ),
    ]
  }
  // Undefined variables are already reported by checkVarRefsInArgs
  return checkOverlapFractionArg(first.value, pos, scope, outputScope, false)
}

// ── Dataset keyword arguments ───────────────────────────────────────

/**
 * Dataset keywords, shared with Plaza's REST `datasets` (geocoding: datasets
 * to search; routing: datasets whose roads to route over),
 * `dataset_name_field` and `avoid_datasets` (routing). Values are dataset
 * slugs or ids, which Plaza resolves. Which computations take them is
 * COMPUTATION_KWARGS.
 */
const DATASET_KWARGS = ["datasets", "dataset_name_field", "avoid_datasets"]

const DATASET_HINT =
  'dataset slugs or ids, or "plaza" / "all", e.g. `datasets: ["census-places"]`'

function checkDatasetKwargValue(
  name: string,
  value: Expr,
  pos: Pos,
): TypeCheckError[] {
  if (name === "dataset_name_field") {
    return value.kind === "string"
      ? []
      : [
          kwargError(
            pos,
            "`dataset_name_field:` must be a string",
            'a property name, e.g. `"title"`',
          ),
        ]
  }
  if (value.kind === "string") {
    return []
  }
  if (value.kind === "list") {
    return value.items.every((item) => item.kind === "string")
      ? []
      : [
          kwargError(
            pos,
            `\`${name}:\` list items must be strings`,
            DATASET_HINT,
          ),
        ]
  }
  return [
    kwargError(
      pos,
      `\`${name}:\` must be a string or a list of strings`,
      DATASET_HINT,
    ),
  ]
}

function checkDatasetKwargs(args: Arg[], pos: Pos): TypeCheckError[] {
  return args.flatMap((arg): TypeCheckError[] =>
    arg.type === "kwarg" && DATASET_KWARGS.includes(arg.name)
      ? checkDatasetKwargValue(arg.name, arg.value, pos)
      : [],
  )
}

// ── Computation keyword arguments ────────────────────────────────────

function checkKwargNames(
  name: string,
  args: Arg[],
  pos: Pos,
): TypeCheckError[] {
  const accepted = COMPUTATION_KWARGS[name] ?? []
  const hint = `accepted keywords: ${accepted.map((k) => `\`${k}:\``).join(", ")}`
  // Truck and transit options elsewhere get their own checks' message.
  return args.flatMap((arg) =>
    arg.type === "kwarg" &&
    !accepted.includes(arg.name) &&
    !TRUCK_OPTIONS.includes(arg.name) &&
    !TRANSIT_OPTIONS.includes(arg.name) &&
    !ACTIVE_OPTIONS.includes(arg.name)
      ? [
          {
            line: pos.line,
            col: pos.col,
            message: `\`${name}()\` does not accept \`${arg.name}:\``,
            hint,
            severity: "error" as const,
          },
        ]
      : [],
  )
}

function checkComputationKwargs(
  name: string,
  args: Arg[],
  pos: Pos,
): TypeCheckError[] {
  const nameErrors = checkKwargNames(name, args, pos)
  return [
    ...nameErrors,
    ...checkComputationOptions(name, args, pos),
    ...checkCostingKwargs(args, pos),
  ]
}

function checkComputationOptions(
  name: string,
  args: Arg[],
  pos: Pos,
): TypeCheckError[] {
  if (name === "geocode" || name === "autocomplete") {
    return [
      ...checkGeocodeOptions(args, pos),
      ...(name === "geocode" ? checkGeocodeInput(args, pos) : []),
    ]
  }
  if (name === "place_lookup") {
    return checkPlaceLookupArgs(args, pos)
  }
  if (name === "centroid") {
    return checkCentroidKwargs(args, pos)
  }
  if (name === "expansion") {
    return checkExpansionKwargs(args, pos)
  }
  if (name !== "reverse_geocode") {
    return []
  }
  const supported = REVERSE_GEOCODE_INCLUDES.map((v) => `"${v}"`).join(", ")
  const includeError = (message: string): TypeCheckError => ({
    line: pos.line,
    col: pos.col,
    message,
    hint: `supported values: ${supported}`,
    severity: "error",
  })
  const checkValue = (value: Expr): TypeCheckError[] => {
    if (value.kind !== "string") {
      return [includeError("`include:` list items must be strings")]
    }
    if (REVERSE_GEOCODE_INCLUDES.includes(value.value)) {
      return []
    }
    return [
      includeError(
        `unknown \`include:\` value "${value.value}" for \`reverse_geocode()\``,
      ),
    ]
  }

  return args.flatMap((arg) => {
    if (arg.type !== "kwarg" || arg.name !== "include") {
      return []
    }
    if (arg.value.kind === "string") {
      return checkValue(arg.value)
    }
    if (arg.value.kind === "list") {
      return arg.value.items.flatMap(checkValue)
    }
    return [includeError("`include:` must be a string or a list of strings")]
  })
}

// ── Costing, per-point and recosting options ──────────────────────────
// Value shapes only, as lib/plazaql/type_checker.ex: Plaza checks which
// modes and computations take each option and the per-point counts.

const COSTING_EXAMPLE =
  "e.g. `route(origin: ..., destination: ..., use_tolls: 0, top_speed: 100)`"
const LOCATION_EXAMPLE =
  'e.g. `location_types: ["break", "through", "break"]`, `headings: "90;;"`'
const RECOSTING_EXAMPLE =
  'each "name: key=value, ...", with an optional mode=auto, foot, bicycle, motorcycle or motor_scooter'

function checkCostingKwargs(args: Arg[], pos: Pos): TypeCheckError[] {
  return args.flatMap((arg) => {
    if (arg.type !== "kwarg") {
      return []
    }
    const expected = costingValueError(arg.name, arg.value)
    if (expected === null) {
      return []
    }
    const hint = LOCATION_OPTIONS.includes(arg.name)
      ? LOCATION_EXAMPLE
      : arg.name === "recostings"
        ? RECOSTING_EXAMPLE
        : COSTING_EXAMPLE
    return [kwargError(pos, `\`${arg.name}:\` must be ${expected}`, hint)]
  })
}

const inRange = (value: Expr, min: number, max: number): boolean =>
  value.kind === "number" && value.value >= min && value.value <= max

const preferenceError = (value: Expr): string | null =>
  inRange(value, 0, 1)
    ? null
    : "a number from 0 (avoid) through 0.5 (neutral) to 1 (prefer)"

const speedError =
  (min: number, what: string) =>
  (value: Expr): string | null =>
    value.kind === "number" &&
    Number.isInteger(value.value) &&
    inRange(value, min, 252)
      ? null
      : `${what} in whole km/h from ${min} to 252`

const penaltyError = (value: Expr): string | null =>
  inRange(value, 0, 3600) ? null : "seconds from 0 to 3600"

const degreesError =
  (max: number, what: string) =>
  (value: Expr): string | null =>
    value.kind === "string" ||
    (value.kind === "list" &&
      value.items.every((item) => inRange(item, 0, max)))
      ? null
      : `${what} in degrees from 0 to ${max} per point, or a ";"-separated string with empty entries for points without one`

const recostingsError = (value: Expr): string | null =>
  value.kind === "list" && value.items.every((item) => item.kind === "string")
    ? null
    : 'a list of strings such as ["no_tolls: use_tolls=0", "walk: mode=foot"]'

const COSTING_CHECKS: Record<string, (value: Expr) => string | null> = {
  ...Object.fromEntries(
    COSTING_PREFERENCES.map((name) => [name, preferenceError]),
  ),
  ...Object.fromEntries(COSTING_PENALTIES.map((name) => [name, penaltyError])),
  shortest: (value) => (value.kind === "bool" ? null : "true or false"),
  top_speed: speedError(10, "a speed cap"),
  fixed_speed: speedError(1, "the speed on every road"),
  location_types: (value) => perPointError(value, ["break", "through", "via"]),
  preferred_sides: (value) =>
    perPointError(value, ["same", "opposite", "either"]),
  approaches: (value) => perPointError(value, ["unrestricted", "curb"]),
  headings: degreesError(360, "a heading"),
  heading_tolerances: degreesError(180, "a tolerance"),
  recostings: recostingsError,
}

function costingValueError(name: string, value: Expr): string | null {
  const check = COSTING_CHECKS[name]
  return check ? check(value) : null
}

function perPointError(value: Expr, allowed: string[]): string | null {
  if (value.kind === "string") {
    return null
  }
  const ok =
    value.kind === "list" &&
    value.items.every(
      (item) =>
        item.kind === "string" &&
        (item.value === "" || allowed.includes(item.value)),
    )
  return ok
    ? null
    : `one entry per point (origin, waypoints, destination): ${allowed
        .map((v) => `"${v}"`)
        .join(", ")
        .replace(/, ([^,]*)$/, " or $1")}, or a ";"-separated string`
}

// ── Truck vehicle options (route/isochrone/matrix with mode: "truck") ─

const TRUCK_HINT =
  'e.g. `route(origin: ..., destination: ..., mode: "truck", height: 4.0, weight: 30, hazmat: true)`'

function checkTruckKwargs(
  name: string,
  args: Arg[],
  pos: Pos,
): TypeCheckError[] {
  const truckArgs = args.filter(
    (arg) => arg.type === "kwarg" && TRUCK_OPTIONS.includes(arg.name),
  )
  if (truckArgs.length === 0) {
    return []
  }
  return [
    ...checkTruckUsage(name, args, pos),
    ...truckArgs.flatMap((arg) => checkTruckValue(arg, pos)),
  ]
}

function checkTruckUsage(
  name: string,
  args: Arg[],
  pos: Pos,
): TypeCheckError[] {
  if (!TRUCK_OPTION_COMPUTATIONS.includes(name)) {
    return [
      kwargError(
        pos,
        `\`${name}()\` has no truck options; they apply to ${TRUCK_OPTION_COMPUTATION_NAMES} with \`mode: "truck"\``,
        TRUCK_HINT,
      ),
    ]
  }
  // A mode that is not a literal (a variable, say) is checked by Plaza when
  // it runs; only a missing mode or a literal other than "truck" is an error.
  const mode = args.find((arg) => arg.type === "kwarg" && arg.name === "mode")
  if (mode && mode.type === "kwarg") {
    const literal = mode.value.kind === "string" || mode.value.kind === "atom"
    const truck = mode.value.kind === "string" && mode.value.value === "truck"
    if (truck || !literal) {
      return []
    }
  }
  const names = TRUCK_OPTIONS.map((option) => `\`${option}:\``).join(", ")
  return [
    kwargError(
      pos,
      `truck options (${names}) need \`mode: "truck"\``,
      TRUCK_HINT,
    ),
  ]
}

function checkTruckValue(arg: Arg, pos: Pos): TypeCheckError[] {
  if (arg.type !== "kwarg") {
    return []
  }
  const { name, value } = arg
  if (TRUCK_DIMENSIONS.includes(name)) {
    if (value.kind === "number" && value.value > 0) {
      return []
    }
    const unit = ["height", "width", "length"].includes(name)
      ? "metres"
      : "tonnes"
    return [
      kwargError(
        pos,
        `\`${name}:\` must be a positive number (${unit})`,
        TRUCK_HINT,
      ),
    ]
  }
  if (name === "axle_count") {
    if (
      value.kind === "number" &&
      Number.isInteger(value.value) &&
      value.value > 0
    ) {
      return []
    }
    return [
      kwargError(
        pos,
        "`axle_count:` must be a whole number of axles",
        TRUCK_HINT,
      ),
    ]
  }
  if (value.kind === "bool") {
    return []
  }
  return [kwargError(pos, "`hazmat:` must be `true` or `false`", TRUCK_HINT)]
}

// ── Transit options (route/isochrone with mode: "transit") ──────────

const TRANSIT_HINT =
  'e.g. `route(origin: ..., destination: ..., mode: "transit", depart_at: "2026-03-16T08:00:00-04:00", max_walk_m: 800)`'

function checkTransitKwargs(
  name: string,
  args: Arg[],
  pos: Pos,
): TypeCheckError[] {
  const transitArgs = args.filter(
    (arg) => arg.type === "kwarg" && TRANSIT_OPTIONS.includes(arg.name),
  )
  if (transitArgs.length === 0) {
    return []
  }
  return [
    ...checkTransitUsage(name, args, pos),
    ...checkArriveBy(name, args, pos),
    ...transitArgs.flatMap((arg) => checkTransitValue(arg, pos)),
  ]
}

// An isochrone's budget is `time:` (seconds) or `distance:` (meters), not both.
function checkIsochroneBudget(
  name: string,
  args: Arg[],
  pos: Pos,
): TypeCheckError[] {
  const has = (key: string) =>
    args.some((arg) => arg.type === "kwarg" && arg.name === key)
  if (name !== "isochrone" || !(has("time") && has("distance"))) {
    return []
  }
  return [
    kwargError(
      pos,
      "`time:` and `distance:` can't be combined",
      "an isochrone's budget is `time:` in seconds or `distance:` in meters",
    ),
  ]
}

// arrive_by: the latest departure arriving by then, for a transit route. An
// isochrone spreads out from its departure, so it has no arrival time.
function checkArriveBy(name: string, args: Arg[], pos: Pos): TypeCheckError[] {
  const has = (key: string) =>
    args.some((arg) => arg.type === "kwarg" && arg.name === key)
  if (!has("arrive_by")) {
    return []
  }
  if (name === "isochrone") {
    return [
      kwargError(
        pos,
        "`arrive_by:` is supported by transit routes, not isochrones",
        "an isochrone spreads out from `depart_at:`",
      ),
    ]
  }
  if (has("depart_at")) {
    return [
      kwargError(
        pos,
        "`depart_at:` and `arrive_by:` can't be combined",
        "`depart_at:` leaves at a time; `arrive_by:` finds the latest departure arriving by one",
      ),
    ]
  }
  return []
}

function checkTransitUsage(
  name: string,
  args: Arg[],
  pos: Pos,
): TypeCheckError[] {
  if (!TRANSIT_COMPUTATIONS.includes(name)) {
    return [
      kwargError(
        pos,
        `\`${name}()\` has no transit options; they apply to \`route()\` and \`isochrone()\` with \`mode: "transit"\``,
        TRANSIT_HINT,
      ),
    ]
  }
  // As for truck options: a mode that is not a literal is checked by Plaza.
  const mode = args.find((arg) => arg.type === "kwarg" && arg.name === "mode")
  if (mode && mode.type === "kwarg") {
    const literal = mode.value.kind === "string" || mode.value.kind === "atom"
    const transit =
      mode.value.kind === "string" && mode.value.value === "transit"
    if (transit || !literal) {
      return []
    }
  }
  const names = TRANSIT_OPTIONS.map((option) => `\`${option}:\``).join(", ")
  return [
    kwargError(
      pos,
      `transit options (${names}) need \`mode: "transit"\``,
      TRANSIT_HINT,
    ),
  ]
}

function checkTransitValue(arg: Arg, pos: Pos): TypeCheckError[] {
  if (arg.type !== "kwarg") {
    return []
  }
  const { name, value } = arg
  const isNumber = value.kind === "number"
  if (name === "arrive_by") {
    return value.kind === "string" && value.value !== "now"
      ? []
      : [
          kwargError(
            pos,
            "`arrive_by:` must be an ISO 8601 datetime string",
            'e.g. `arrive_by: "2026-03-16T09:00:00-04:00"`; without an offset, local time at the transit feed',
          ),
        ]
  }
  if (TRANSIT_PREFERENCES.includes(name)) {
    return isNumber && value.value >= 0 && value.value <= 1
      ? []
      : [
          kwargError(
            pos,
            `\`${name}:\` must be a number from 0 to 1`,
            "0 never uses it; 1 (default) has no penalty",
          ),
        ]
  }
  if (name === "max_walk_m") {
    return isNumber && value.value >= 0
      ? []
      : [
          kwargError(
            pos,
            "`max_walk_m:` must be a non-negative number of meters",
            "the longest walk to, between and from stops",
          ),
        ]
  }
  return isNumber && Number.isInteger(value.value) && value.value >= 0
    ? []
    : [
        kwargError(
          pos,
          "`max_transfers:` must be a whole number",
          "the most changes between vehicles",
        ),
      ]
}

// ── Mode options (bicycle, foot, motorcycle, motor_scooter) ─────────

const ACTIVE_HINT =
  'e.g. `route(origin: ..., destination: ..., mode: "bicycle", bicycle_type: "road", use_hills: 0.2)`, `route(..., mode: "foot", walking_speed: 4, wheelchair: true)` or `route(..., mode: "motorcycle", style: "adventure")`'

/** Canonical mode, its literals and its option keywords, in message order. */
const ACTIVE_FAMILIES: [string, string[], string[]][] = [
  ["bicycle", BICYCLE_MODES, BICYCLE_OPTIONS],
  ["foot", FOOT_MODES, PEDESTRIAN_OPTIONS],
  ["motorcycle", MOTORCYCLE_MODES, MOTORCYCLE_OPTIONS],
  ["motor_scooter", MOTOR_SCOOTER_MODES, MOTOR_SCOOTER_OPTIONS],
]

/**
 * `wheelchair:` is also a transit option of route() and isochrone().
 * ev_route() plans electric motorcycles and scooters only.
 */
function activeFamilies(name: string): [string, string[], string[]][] {
  if (name === "ev_route") {
    return ACTIVE_FAMILIES.filter(([mode]) =>
      ["motorcycle", "motor_scooter"].includes(mode),
    )
  }
  return TRANSIT_COMPUTATIONS.includes(name)
    ? [...ACTIVE_FAMILIES, ["transit", ["transit"], TRANSIT_ACTIVE_OPTIONS]]
    : ACTIVE_FAMILIES
}

function checkActiveKwargs(
  name: string,
  args: Arg[],
  pos: Pos,
): TypeCheckError[] {
  const activeArgs = args.filter(
    (arg) => arg.type === "kwarg" && ACTIVE_OPTIONS.includes(arg.name),
  )
  if (activeArgs.length === 0) {
    return []
  }
  const keys = activeArgs.flatMap((arg) =>
    arg.type === "kwarg" ? [arg.name] : [],
  )
  return [
    ...checkActiveUsage(name, args, keys, pos),
    ...activeArgs.flatMap((arg) => checkActiveValue(arg, pos)),
  ]
}

function checkActiveUsage(
  name: string,
  args: Arg[],
  keys: string[],
  pos: Pos,
): TypeCheckError[] {
  if (name === "ev_route") {
    const rider = [...MOTORCYCLE_OPTIONS, ...MOTOR_SCOOTER_OPTIONS]
    const others = [...new Set(keys.filter((key) => !rider.includes(key)))]
    if (others.length > 0) {
      return [
        kwargError(
          pos,
          `\`ev_route()\` has no ${others.map((key) => `\`${key}:\``).join(", ")}; it takes the motorcycle and motor scooter options, with \`mode: "motorcycle"\` or \`"motor_scooter"\``,
          'e.g. `ev_route(..., battery: 15000, mode: "motorcycle", style: "touring")`',
        ),
      ]
    }
  } else if (!ACTIVE_COMPUTATIONS.includes(name)) {
    return [
      kwargError(
        pos,
        `\`${name}()\` has no bicycle, pedestrian or motorcycle options; they apply to ${VEHICLE_COMPUTATION_NAMES} with \`mode: "bicycle"\`, \`"foot"\`, \`"motorcycle"\` or \`"motor_scooter"\`, and the motorcycle and motor scooter ones to \`ev_route()\``,
        ACTIVE_HINT,
      ),
    ]
  }
  const mode = activeMode(args)
  if (mode === "dynamic") {
    // As for truck options: a mode that is not a literal is checked by Plaza.
    return []
  }
  const families = activeFamilies(name)
  const family = families.find(([, literals]) => literals.includes(mode))
  const stray = family ? keys.filter((key) => !family[2].includes(key)) : keys
  return activeModeError(families, stray, pos)
}

/** The `mode:` literal given ("" for none or an atom), or "dynamic" for a variable. */
function activeMode(args: Arg[]): string {
  const mode = args.find((arg) => arg.type === "kwarg" && arg.name === "mode")
  if (mode?.type !== "kwarg") {
    return ""
  }
  const { value } = mode
  if (value.kind === "string") {
    return value.value
  }
  return value.kind === "atom" ? "" : "dynamic"
}

/** The modes taking every one of `keys` (else those taking any of them). */
function activeModeError(
  families: [string, string[], string[]][],
  keys: string[],
  pos: Pos,
): TypeCheckError[] {
  const unique = [...new Set(keys)]
  if (unique.length === 0) {
    return []
  }
  let modes = families
    .filter(([, , options]) => unique.every((key) => options.includes(key)))
    .map(([mode]) => mode)
  if (modes.length === 0) {
    modes = families
      .filter(([, , options]) => unique.some((key) => options.includes(key)))
      .map(([mode]) => mode)
  }
  const quotedModes = modes.map((mode) => `\`mode: "${mode}"\``)
  const needed =
    quotedModes.length === 1
      ? quotedModes[0]
      : `${quotedModes.slice(0, -1).join(", ")} or ${quotedModes.at(-1)}`
  const names = unique.map((key) => `\`${key}:\``).join(", ")
  return [kwargError(pos, `${names} need ${needed}`, ACTIVE_HINT)]
}

function checkActiveValue(arg: Arg, pos: Pos): TypeCheckError[] {
  if (arg.type !== "kwarg") {
    return []
  }
  switch (arg.name) {
    case "bicycle_type":
      return checkBicycleType(arg.value, pos)
    case "style":
      return arg.value.kind === "string" &&
        MOTORCYCLE_STYLES.includes(arg.value.value)
        ? []
        : [
            kwargError(
              pos,
              `\`style:\` must be one of ${quoted(MOTORCYCLE_STYLES)}`,
              '"touring" (direct, paved) or "adventure" (curvy roads, tracks OK)',
            ),
          ]
    case "wheelchair":
      return arg.value.kind === "bool"
        ? []
        : [
            kwargError(
              pos,
              "`wheelchair:` must be `true` or `false`",
              ACTIVE_HINT,
            ),
          ]
    case "lane_splitting":
      return arg.value.kind === "bool"
        ? []
        : [
            kwargError(
              pos,
              "`lane_splitting:` must be `true` or `false`",
              "whether the rider filters between lanes of queued traffic (legal only in some places)",
            ),
          ]
    case "max_hiking_difficulty":
      return checkHikingDifficulty(arg.value, pos)
    default:
      return checkActiveRange(arg.name, arg.value, pos)
  }
}

function checkBicycleType(value: Expr, pos: Pos): TypeCheckError[] {
  return value.kind === "string" && BICYCLE_TYPES.includes(value.value)
    ? []
    : [
        kwargError(
          pos,
          `\`bicycle_type:\` must be one of ${quoted(BICYCLE_TYPES)}`,
          ACTIVE_HINT,
        ),
      ]
}

// Whole numbers only; `3.0` counts, as in Elixir and in Plaza.
function checkHikingDifficulty(value: Expr, pos: Pos): TypeCheckError[] {
  const valid =
    value.kind === "number" &&
    Number.isInteger(value.value) &&
    value.value >= 1 &&
    value.value <= 6
  return valid
    ? []
    : [
        kwargError(
          pos,
          "`max_hiking_difficulty:` must be a whole number from 1 to 6",
          "the hardest trail on the SAC scale: 1 hiking to 6 difficult alpine hiking",
        ),
      ]
}

function checkActiveRange(
  name: string,
  value: Expr,
  pos: Pos,
): TypeCheckError[] {
  const range = ACTIVE_RANGES.get(name)
  if (!range) {
    return []
  }
  const [min, max, unit] = range
  if (value.kind === "number" && value.value >= min && value.value <= max) {
    return []
  }
  const suffix = unit ? ` (${unit})` : ""
  return [
    kwargError(
      pos,
      `\`${name}:\` must be a number from ${min} to ${max}${suffix}`,
      ACTIVE_HINT,
    ),
  ]
}

const quoted = (values: string[]): string =>
  values.map((v) => `"${v}"`).join(", ")

function kwargError(pos: Pos, message: string, hint: string): TypeCheckError {
  return { line: pos.line, col: pos.col, message, hint, severity: "error" }
}

function checkCentroidKwargs(args: Arg[], pos: Pos): TypeCheckError[] {
  return args.flatMap((arg) => {
    if (arg.type !== "kwarg" || arg.name !== "metric") {
      return []
    }
    if (
      arg.value.kind === "string" &&
      CENTROID_METRICS.includes(arg.value.value)
    ) {
      return []
    }
    return [
      kwargError(
        pos,
        `\`metric:\` must be one of ${quoted(CENTROID_METRICS)}`,
        "the total travel cost the meeting point minimises",
      ),
    ]
  })
}

function checkExpansionKwargs(args: Arg[], pos: Pos): TypeCheckError[] {
  return [
    ...checkExpansionAction(args, pos),
    ...args.flatMap((arg) =>
      arg.type === "kwarg" && arg.name === "expansion_properties"
        ? checkExpansionProperties(arg.value, pos)
        : [],
    ),
  ]
}

function checkExpansionAction(args: Arg[], pos: Pos): TypeCheckError[] {
  const action = args.find((a) => a.type === "kwarg" && a.name === "action")
  if (!action || action.type !== "kwarg") {
    return [
      kwargError(
        pos,
        "`expansion()` requires `action:`",
        `one of ${quoted(EXPANSION_ACTIONS)}`,
      ),
    ]
  }
  if (
    action.value.kind === "string" &&
    EXPANSION_ACTIONS.includes(action.value.value)
  ) {
    return []
  }
  return [
    kwargError(
      pos,
      `\`action:\` must be one of ${quoted(EXPANSION_ACTIONS)}`,
      "the request whose search to show",
    ),
  ]
}

function checkExpansionProperties(value: Expr, pos: Pos): TypeCheckError[] {
  const hint = `supported: ${quoted(EXPANSION_PROPERTIES)}`
  if (value.kind !== "list") {
    return [
      kwargError(
        pos,
        "`expansion_properties:` must be a list of strings",
        hint,
      ),
    ]
  }
  return value.items.flatMap((item) => {
    if (item.kind !== "string") {
      return [
        kwargError(
          pos,
          "`expansion_properties:` list items must be strings",
          hint,
        ),
      ]
    }
    if (EXPANSION_PROPERTIES.includes(item.value)) {
      return []
    }
    return [
      kwargError(
        pos,
        `unknown \`expansion_properties:\` value "${item.value}"`,
        hint,
      ),
    ]
  })
}

// ── Geocoding ────────────────────────────────────────────────────────

const BOUNDARY_GID = /^osm:(way|relation):[1-9][0-9]{0,18}$/
const GID = /^osm:(node|way|relation|address|place):[1-9][0-9]{0,18}$/
const MAX_PLACE_IDS = 50
const STRUCTURED_REQUIRED = ["address", "locality", "region", "postalcode"]
const GID_HINT =
  'GIDs look like "osm:node:123", "osm:way:456" or "osm:relation:789"'

function geocodeError(
  message: string,
  pos: Pos,
  hint?: string,
): TypeCheckError {
  return { line: pos.line, col: pos.col, message, hint, severity: "error" }
}

const LAYERS_HINT = `supported: ${GEOCODE_LAYERS.map((v) => `"${v}"`).join(", ")}`
const BOUNDARY_HINT =
  'a way or relation GID, e.g. `boundary_gid: "osm:relation:62422"`'

function checkLayerValue(value: string, pos: Pos): TypeCheckError[] {
  return GEOCODE_LAYERS.includes(value)
    ? []
    : [geocodeError(`unknown \`layers:\` value "${value}"`, pos, LAYERS_HINT)]
}

function checkLayersOption(value: Expr, pos: Pos): TypeCheckError[] {
  if (value.kind === "string") {
    return value.value
      .split(",")
      .map((v) => v.trim())
      .filter((v) => v !== "")
      .flatMap((v) => checkLayerValue(v, pos))
  }
  if (value.kind === "list") {
    return value.items.flatMap((item) =>
      item.kind === "string"
        ? checkLayerValue(item.value, pos)
        : [
            geocodeError(
              "`layers:` list items must be strings",
              pos,
              LAYERS_HINT,
            ),
          ],
    )
  }
  return [
    geocodeError(
      "`layers:` must be a string or a list of strings",
      pos,
      LAYERS_HINT,
    ),
  ]
}

function checkBoundaryGidOption(value: Expr, pos: Pos): TypeCheckError[] {
  if (value.kind !== "string") {
    return [
      geocodeError("`boundary_gid:` must be a string", pos, BOUNDARY_HINT),
    ]
  }
  return BOUNDARY_GID.test(value.value)
    ? []
    : [
        geocodeError(
          `invalid \`boundary_gid:\` "${value.value}"`,
          pos,
          BOUNDARY_HINT,
        ),
      ]
}

function checkComponentOption(
  name: string,
  value: Expr,
  pos: Pos,
): TypeCheckError[] {
  if (
    value.kind === "string" ||
    (name === "postalcode" && value.kind === "number")
  ) {
    return []
  }
  return [geocodeError(`\`${name}:\` must be a string`, pos)]
}

function checkGeocodeOptions(args: Arg[], pos: Pos): TypeCheckError[] {
  return args.flatMap((arg): TypeCheckError[] => {
    if (arg.type !== "kwarg") {
      return []
    }
    if (arg.name === "layers") {
      return checkLayersOption(arg.value, pos)
    }
    if (arg.name === "boundary_gid") {
      return checkBoundaryGidOption(arg.value, pos)
    }
    if (STRUCTURED_GEOCODE_COMPONENTS.includes(arg.name)) {
      return checkComponentOption(arg.name, arg.value, pos)
    }
    return []
  })
}

function checkGeocodeInput(args: Arg[], pos: Pos): TypeCheckError[] {
  const hasQuery = args.some(
    (arg) =>
      (arg.type === "posarg" && arg.value.kind === "string") ||
      (arg.type === "kwarg" &&
        (arg.name === "query" || arg.name === "addresses")),
  )
  const hasComponent = args.some(
    (arg) => arg.type === "kwarg" && STRUCTURED_REQUIRED.includes(arg.name),
  )
  if (hasQuery || hasComponent) {
    return []
  }
  return [
    geocodeError(
      "`geocode()` needs an address string or one of `address:`, `locality:`, `region:`, `postalcode:`",
      pos,
      'e.g. `geocode("1600 Pennsylvania Ave, Washington DC")` or `geocode(address: "1600 Pennsylvania Ave", locality: "Washington", region: "DC")`',
    ),
  ]
}

function checkPlaceLookupArgs(args: Arg[], pos: Pos): TypeCheckError[] {
  const gids: Expr[] = args.flatMap((arg): Expr[] => {
    if (arg.type === "posarg") {
      return [arg.value]
    }
    if (arg.name !== "ids") {
      return []
    }
    return arg.value.kind === "list" ? arg.value.items : [arg.value]
  })

  if (gids.length === 0) {
    return [
      geocodeError("`place_lookup()` needs at least one GID", pos, GID_HINT),
    ]
  }
  if (gids.length > MAX_PLACE_IDS) {
    return [
      geocodeError(
        `\`place_lookup()\` takes at most ${MAX_PLACE_IDS} GIDs`,
        pos,
        GID_HINT,
      ),
    ]
  }
  return gids.flatMap((gid) => {
    if (gid.kind !== "string") {
      return [geocodeError("`place_lookup()` takes GID strings", pos, GID_HINT)]
    }
    return GID.test(gid.value)
      ? []
      : [geocodeError(`invalid GID "${gid.value}"`, pos, GID_HINT)]
  })
}

// ── Contextual requirements ──────────────────────────────────────────

function checkContextual(
  methodName: string,
  args: Arg[] | TagFilter[],
  ctx: ChainContext,
  pos: Pos,
): TypeCheckError[] {
  if (methodName === "tile") {
    return isArgArray(args)
      ? checkTileArgs(args, pos)
      : checkTileFilterArgs(args, pos)
  }

  if (
    (methodName === "offset" && ctx.hasCursor) ||
    (methodName === "cursor" && ctx.hasOffset)
  ) {
    return [
      {
        line: pos.line,
        col: pos.col,
        message: "`.cursor()` and `.offset()` cannot be combined",
        hint: "page with `.cursor(...)` alone; the cursor already says where the page starts",
        severity: "error",
      },
    ]
  }

  if (methodName === "cursor" && !isCursorArgs(args)) {
    return [
      {
        line: pos.line,
        col: pos.col,
        message:
          "`.cursor()` takes one string, the `next_cursor` of the previous page",
        hint: 'copy the token from the response: .cursor("SFMyNTY...")',
        severity: "error",
      },
    ]
  }

  if (methodName === "offset" && !ctx.hasLimit) {
    return [
      {
        line: pos.line,
        col: pos.col,
        message: "`.offset()` requires `.limit()` to be set",
        hint: "add `.limit(n)` before `.offset()`: ...limit(20).offset(10)",
        severity: "error",
      },
    ]
  }

  return []
}

// .tile(z, x, y, layers?: [...]) — mirrors PlazaQL.TypeChecker
const MAX_TILE_ZOOM = 22

function tileError(pos: Pos, message: string, hint: string): TypeCheckError {
  return { line: pos.line, col: pos.col, message, hint, severity: "error" }
}

// With a scalar keyword (`layers: "pois"`, `format: "pbf"`) the parser reads
// the argument list as tag filters and drops the coordinates, so only the
// keyword names can be checked here; PlazaQL.TypeChecker checks the rest.
function checkTileFilterArgs(filters: TagFilter[], pos: Pos): TypeCheckError[] {
  return filters
    .filter((f) => f.key !== "layers")
    .map((f) =>
      tileError(
        pos,
        `unknown \`.tile()\` argument \`${f.key}:\``,
        '`.tile(z, x, y)` takes one keyword argument, `layers: ["pois", ...]`',
      ),
    )
}

function checkTileArgs(args: Arg[], pos: Pos): TypeCheckError[] {
  const coords = args
    .filter((a): a is PosArg => a.type === "posarg")
    .map((a) => a.value)
  const kwargs = args.filter((a): a is KwArg => a.type === "kwarg")
  return [
    ...checkTileCoords(coords, pos),
    ...kwargs.flatMap((arg) => checkTileKwarg(arg, pos)),
  ]
}

function checkTileCoords(coords: Expr[], pos: Pos): TypeCheckError[] {
  const ints = coords.map((c) =>
    c.kind === "number" && Number.isInteger(c.value) ? c.value : null,
  )
  if (ints.length !== 3 || ints.some((n) => n === null)) {
    return [
      tileError(
        pos,
        "`.tile()` requires three integer arguments: zoom, x and y",
        "e.g., `.tile(14, 4823, 6160)`",
      ),
    ]
  }
  const [z, x, y] = ints as [number, number, number]
  if (z < 0 || z > MAX_TILE_ZOOM) {
    return [
      tileError(
        pos,
        `\`.tile()\` zoom must be between 0 and ${MAX_TILE_ZOOM}, got ${z}`,
        "the server serves zoom levels its tile endpoint documents",
      ),
    ]
  }
  const size = 2 ** z
  const inGrid = (n: number) => n >= 0 && n < size
  if (!(inGrid(x) && inGrid(y))) {
    return [
      tileError(
        pos,
        `\`.tile(${z}, ${x}, ${y})\` is outside the grid: x and y must be between 0 and ${size - 1} at zoom ${z}`,
        "x and y are slippy-map tile coordinates",
      ),
    ]
  }
  return []
}

function checkTileKwarg(arg: KwArg, pos: Pos): TypeCheckError[] {
  if (arg.name !== "layers") {
    return [
      tileError(
        pos,
        `unknown \`.tile()\` argument \`${arg.name}:\``,
        '`.tile(z, x, y)` takes one keyword argument, `layers: ["pois", ...]`',
      ),
    ]
  }
  const value = arg.value
  const valid =
    value.kind === "string" ||
    (value.kind === "list" &&
      value.items.length > 0 &&
      value.items.every((i) => i.kind === "string"))
  return valid
    ? []
    : [
        tileError(
          pos,
          "`.tile()` `layers:` must be a non-empty list of layer names",
          'e.g., `layers: ["pois", "buildings"]`',
        ),
      ]
}

// ── Type guard ───────────────────────────────────────────────────────

// .cursor("token"): exactly one positional string — mirrors PlazaQL.TypeChecker
function isCursorArgs(args: Arg[] | TagFilter[]): boolean {
  if (!isArgArray(args) || args.length !== 1) {
    return false
  }
  const [arg] = args
  return arg.type === "posarg" && arg.value.kind === "string"
}

function isArgArray(args: Arg[] | TagFilter[]): args is Arg[] {
  if (args.length === 0) {
    return true
  }
  const first = args[0] as (typeof args)[0]
  return "type" in first && (first.type === "posarg" || first.type === "kwarg")
}

// ── Exported helpers for LSP features ────────────────────────────────

export function inferExprType(
  expr: Expr,
  scope: Scope,
  outputScope?: Scope,
): PqlType {
  return checkExpr(expr, scope, outputScope ?? new Map()).type
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: parser helper
export function getExprAtPosition(
  ast: Statement[],
  line: number,
  _col: number,
): { expr: Expr | null; scope: Scope; outputScope: Scope } {
  const scope: Scope = new Map()
  const outputScope: Scope = new Map()
  let targetExpr: Expr | null = null

  for (let i = 0; i < ast.length; i++) {
    const stmt = ast[i] as Statement
    const nextLine = ast[i + 1]?.pos.line ?? Number.POSITIVE_INFINITY

    // Build scope
    if (stmt.kind === "var_assign") {
      const type = checkExpr(stmt.expr, scope, outputScope).type
      scope.set(stmt.name, {
        type,
        line: stmt.pos.line,
        col: stmt.pos.col,
        expr: stmt.expr,
      })
    } else if (stmt.kind === "output" && stmt.name !== null) {
      const type = checkExpr(stmt.expr, scope, outputScope).type
      const key = `$$.${stmt.name}`
      outputScope.set(key, {
        type,
        line: stmt.pos.line,
        col: stmt.pos.col,
        expr: stmt.expr,
      })
    }

    // Find the statement that contains the cursor line
    if (stmt.pos.line <= line && line < nextLine) {
      const expr =
        stmt.kind === "settings"
          ? null
          : stmt.kind === "var_assign"
            ? stmt.expr
            : stmt.expr
      targetExpr = expr
    }
  }

  return { expr: targetExpr, scope, outputScope }
}

export function inferChainStateAtPosition(
  ast: Statement[],
  line: number,
  col: number,
): { type: PqlType; lastGroup: MethodGroup; lastOrdinal: number } {
  const { expr, scope, outputScope } = getExprAtPosition(ast, line, col)
  if (!expr) {
    return { type: "GeoSet", lastGroup: "source", lastOrdinal: 0 }
  }

  return walkExprForChainState(expr, scope, outputScope, line, col)
}

function walkMethodsUpToCursor(
  methods: MethodNode[],
  startType: PqlType,
  startGroup: MethodGroup,
  startOrdinal: number,
  line: number,
  col: number,
): { type: PqlType; lastGroup: MethodGroup; lastOrdinal: number } {
  let currentType = startType
  let lastGroup = startGroup
  let lastOrdinal = startOrdinal

  for (const method of methods) {
    if (
      method.pos.line > line ||
      (method.pos.line === line && method.pos.col >= col)
    ) {
      break
    }
    const result = methodOutputType(method.name, currentType)
    if (result.ok) {
      currentType = result.type
    }
    const mg = methodGroup(method.name)
    const mp = methodPhase(method.name)
    if (GROUP_RANK[mg] > GROUP_RANK[lastGroup]) {
      lastGroup = mg
    }
    lastOrdinal = mp.ordinal
  }

  return { type: currentType, lastGroup, lastOrdinal }
}

const SOURCE_STATE = { lastGroup: "source" as MethodGroup, lastOrdinal: 0 }

const CHAIN_STATE_BY_KIND: Partial<Record<Expr["kind"], PqlType>> = {
  boundary: "Boundary",
  point: "Point",
  bbox: "Polygon",
  polygon: "Polygon",
  circle: "Polygon",
  linestring: "LineString",
}

function walkExprForChainState(
  expr: Expr,
  scope: Scope,
  outputScope: Scope,
  line: number,
  col: number,
): { type: PqlType; lastGroup: MethodGroup; lastOrdinal: number } {
  if (expr.kind === "search") {
    const baseType = searchBaseType(expr.elementType)
    return walkMethodsUpToCursor(expr.methods, baseType, "source", 0, line, col)
  }

  if (expr.kind === "chain") {
    const { base, methods } = flattenChain(expr)
    const baseResult = walkExprForChainState(
      base,
      scope,
      outputScope,
      line,
      col,
    )
    return walkMethodsUpToCursor(
      methods,
      baseResult.type,
      baseResult.lastGroup,
      baseResult.lastOrdinal,
      line,
      col,
    )
  }

  if (expr.kind === "union") {
    const left = walkExprForChainState(expr.left, scope, outputScope, line, col)
    const right = walkExprForChainState(
      expr.right,
      scope,
      outputScope,
      line,
      col,
    )
    return { type: unionType(left.type, right.type), ...SOURCE_STATE }
  }
  if (expr.kind === "difference") {
    const left = walkExprForChainState(expr.left, scope, outputScope, line, col)
    return { type: left.type, ...SOURCE_STATE }
  }

  if (expr.kind === "var_ref") {
    const info = scope.get(expr.name)
    return { type: info?.type ?? "GeoSet", ...SOURCE_STATE }
  }
  if (expr.kind === "output_ref") {
    const info = outputScope.get(`$$.${expr.name}`)
    return { type: info?.type ?? "GeoSet", ...SOURCE_STATE }
  }

  if (expr.kind === "computation") {
    return { type: computationType(expr.name), ...SOURCE_STATE }
  }

  const knownType = CHAIN_STATE_BY_KIND[expr.kind]
  if (knownType) {
    return { type: knownType, ...SOURCE_STATE }
  }

  return { type: "GeoSet", ...SOURCE_STATE }
}
