// PlazaQL type checker — ported from Plaza.PlazaQL.TypeChecker

import type {
  PqlType,
  Expr,
  Statement,
  Arg,
  MethodNode,
  TagFilter,
  Pos,
  ChainNode,
} from "./types.js";

import {
  searchBaseType,
  computationType,
  methodPhase,
  isOutputMode,
  methodOutputType,
  validSpatialArgTypes,
  unionType,
} from "./types.js";

// ── Diagnostic ───────────────────────────────────────────────────────

export interface TypeCheckError {
  line: number;
  col: number;
  message: string;
  hint?: string;
  severity: "error" | "warning";
}

// ── Scope ────────────────────────────────────────────────────────────

export interface VarInfo {
  type: PqlType;
  line: number;
  col: number;
  expr: Expr;
}

export type Scope = Map<string, VarInfo>;

// ── Public API ───────────────────────────────────────────────────────

export interface TypeCheckResult {
  errors: TypeCheckError[];
  scope: Scope;
  /** Type of each statement's expression (indexed by statement index) */
  stmtTypes: (PqlType | null)[];
}

export function typeCheck(ast: Statement[]): TypeCheckResult {
  const scope: Scope = new Map();
  const outputScope: Scope = new Map(); // tracks $$.name outputs
  const errors: TypeCheckError[] = [];
  const stmtTypes: (PqlType | null)[] = [];

  for (const stmt of ast) {
    const { errs, type } = checkStatement(stmt, scope, outputScope);
    errors.push(...errs);
    stmtTypes.push(type);
  }

  // Check for at least one output
  const outputs = ast.filter((s) => s.kind === "output");
  const hasNonSettings = ast.some((s) => s.kind !== "settings");
  if (outputs.length === 0 && hasNonSettings) {
    errors.push({
      line: 1,
      col: 1,
      message: "at least one `$$` statement is required",
      hint: 'add `$$ = <expression>;` at the end of your query',
      severity: "error",
    });
  }

  // Check: only one simple $$ = allowed
  const simpleOutputs = outputs.filter((s) => s.kind === "output" && s.name === null);
  if (simpleOutputs.length > 1) {
    for (const s of simpleOutputs.slice(1)) {
      errors.push({
        line: s.pos.line,
        col: s.pos.col,
        message: "only one `$$ = ...` statement is allowed per query",
        hint: "use named outputs (`$$.name = ...`) for multiple results",
        severity: "error",
      });
    }
  }

  // Check: cannot mix simple $$ = and named $$.name =
  const namedOutputs = outputs.filter((s) => s.kind === "output" && s.name !== null);
  if (simpleOutputs.length > 0 && namedOutputs.length > 0) {
    const conflicting = namedOutputs[0]!;
    errors.push({
      line: conflicting.pos.line,
      col: conflicting.pos.col,
      message: "cannot mix simple `$$` and named `$$.name` outputs",
      hint: "use either `$$ = ...` or `$$.name = ...`, not both",
      severity: "error",
    });
  }

  errors.sort((a, b) => a.line - b.line || a.col - b.col);
  return { errors, scope, stmtTypes };
}

// ── Statement checking ───────────────────────────────────────────────

function checkStatement(
  stmt: Statement,
  scope: Scope,
  outputScope: Scope
): { errs: TypeCheckError[]; type: PqlType | null } {
  switch (stmt.kind) {
    case "settings":
      return { errs: [], type: null };

    case "var_assign": {
      const errs: TypeCheckError[] = [];
      if (scope.has(stmt.name)) {
        errs.push({
          line: stmt.pos.line,
          col: stmt.pos.col,
          message: `duplicate variable \`${stmt.name}\``,
          hint: "choose a different name or remove the earlier definition",
          severity: "error",
        });
      }
      const { type, errors: exprErrs } = checkExpr(stmt.expr, scope, outputScope);
      errs.push(...exprErrs);
      scope.set(stmt.name, {
        type,
        line: stmt.pos.line,
        col: stmt.pos.col,
        expr: stmt.expr,
      });
      return { errs, type };
    }

    case "output": {
      const { type, errors: exprErrs } = checkExpr(stmt.expr, scope, outputScope);
      const errs = [...exprErrs];
      // Register named output in outputScope for later $$.name references
      if (stmt.name !== null) {
        const key = `$$.${stmt.name}`;
        if (outputScope.has(key)) {
          errs.push({
            line: stmt.pos.line,
            col: stmt.pos.col,
            message: `duplicate output variable \`${key}\``,
            hint: "choose a different name or remove the earlier definition",
            severity: "error",
          });
        }
        outputScope.set(key, {
          type,
          line: stmt.pos.line,
          col: stmt.pos.col,
          expr: stmt.expr,
        });
      }
      return { errs, type };
    }
  }
}

// ── Expression type checking ─────────────────────────────────────────

interface ExprResult {
  type: PqlType;
  errors: TypeCheckError[];
}

function checkExpr(expr: Expr, scope: Scope, outputScope: Scope): ExprResult {
  switch (expr.kind) {
    case "search": {
      const baseType = searchBaseType(expr.elementType);
      const { finalType, errors } = checkMethodChain(
        expr.methods,
        baseType,
        scope,
        outputScope
      );
      return { type: finalType, errors };
    }

    case "area":
      return { type: "Area", errors: [] };

    case "computation": {
      const type = computationType(expr.name);
      const argErrors = checkVarRefsInArgs(expr.args, scope, outputScope);
      return { type, errors: argErrors };
    }

    case "point":
      return { type: "Point", errors: [] };

    case "bbox":
      return { type: "Polygon", errors: [] };

    case "linestring":
    case "polygon":
    case "circle":
      return {
        type: expr.kind === "linestring" ? "LineString" : "Polygon",
        errors: [],
      };

    case "var_ref": {
      const info = scope.get(expr.name);
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
        };
      }
      return { type: info.type, errors: [] };
    }

    case "output_ref": {
      const key = `$$.${expr.name}`;
      const info = outputScope.get(key);
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
        };
      }
      return { type: info.type, errors: [] };
    }

    case "chain": {
      return checkChain(expr, scope, outputScope);
    }

    case "union": {
      const leftR = checkExpr(expr.left, scope, outputScope);
      const rightR = checkExpr(expr.right, scope, outputScope);
      const resultType = unionType(leftR.type, rightR.type);
      return {
        type: resultType,
        errors: [...leftR.errors, ...rightR.errors],
      };
    }

    case "difference": {
      const leftR = checkExpr(expr.left, scope, outputScope);
      const rightR = checkExpr(expr.right, scope, outputScope);
      return {
        type: leftR.type,
        errors: [...leftR.errors, ...rightR.errors],
      };
    }

    case "arrow_chain": {
      const itemErrors = expr.items.flatMap((item) => checkExpr(item, scope, outputScope).errors);
      return { type: "Point", errors: itemErrors };
    }

    case "list": {
      const itemErrors = expr.items.flatMap((item) => checkExpr(item, scope, outputScope).errors);
      return { type: "Scalar", errors: itemErrors };
    }

    case "number":
    case "string":
    case "identifier":
    case "atom":
    case "bool":
      return { type: "Scalar", errors: [] };

    default:
      return { type: "Scalar", errors: [] };
  }
}

// ── Chain flattening & checking ──────────────────────────────────────

function checkChain(chain: ChainNode, scope: Scope, outputScope: Scope): ExprResult {
  const { base, methods } = flattenChain(chain);
  const baseResult = checkExpr(base, scope, outputScope);
  const { finalType, errors: methodErrors } = checkMethodChain(
    methods,
    baseResult.type,
    scope,
    outputScope
  );
  return {
    type: finalType,
    errors: [...baseResult.errors, ...methodErrors],
  };
}

function flattenChain(node: Expr): { base: Expr; methods: MethodNode[] } {
  const methods: MethodNode[] = [];
  let current = node;
  while (current.kind === "chain") {
    methods.unshift((current as ChainNode).method);
    current = (current as ChainNode).receiver;
  }
  return { base: current, methods };
}

// ── Method chain validation ──────────────────────────────────────────

interface ChainContext {
  lastPhase: number;
  lastPhaseName: string;
  lastMethodName: string | null;
  hasAround: boolean;
  hasLimit: boolean;
  outputModeCount: number;
  currentType: PqlType;
}

function checkMethodChain(
  methods: MethodNode[],
  baseType: PqlType,
  scope: Scope,
  outputScope: Scope
): { finalType: PqlType; errors: TypeCheckError[] } {
  const ctx: ChainContext = {
    lastPhase: 0,
    lastPhaseName: "source",
    lastMethodName: null,
    hasAround: false,
    hasLimit: false,
    outputModeCount: 0,
    currentType: baseType,
  };

  const errors: TypeCheckError[] = [];

  for (const method of methods) {
    const methodErrs = checkMethod(method, ctx, scope, outputScope);
    errors.push(...methodErrs);
  }

  return { finalType: ctx.currentType, errors };
}

function checkMethod(
  method: MethodNode,
  ctx: ChainContext,
  scope: Scope,
  outputScope: Scope
): TypeCheckError[] {
  const { ordinal: phaseNum, label: phaseName } = methodPhase(method.name);
  const errors: TypeCheckError[] = [];

  // 1. Phase ordering
  if (phaseNum > 0 && phaseNum < ctx.lastPhase) {
    errors.push({
      line: method.pos.line,
      col: method.pos.col,
      message: `\`.${method.name}()\` is ${phaseName} — cannot follow \`.${ctx.lastMethodName}()\` which is ${ctx.lastPhaseName}`,
      hint: `reorder methods so that ${phaseName} comes before ${ctx.lastPhaseName}`,
      severity: "error",
    });
  }

  // 2. Output mode exclusivity
  if (isOutputMode(method.name) && ctx.outputModeCount > 0) {
    errors.push({
      line: method.pos.line,
      col: method.pos.col,
      message: `multiple output modes — \`.${method.name}()\` conflicts with earlier output mode`,
      hint: "use only one output mode per chain (`.count()`, `.ids()`, `.tags()`, or `.skel()`)",
      severity: "error",
    });
  }

  // 3. Method-type compatibility
  const compat = methodOutputType(method.name, ctx.currentType);
  if (compat.ok) {
    ctx.currentType = compat.type;
  } else {
    errors.push({
      line: method.pos.line,
      col: method.pos.col,
      message: compat.error,
      hint: simplifyHint(method.name, ctx.currentType),
      severity: "error",
    });
  }

  // 4. Spatial arg type checking
  errors.push(...checkSpatialArgs(method.name, method.args, method.pos, scope, outputScope));

  // 5. Var refs in args (only for Arg[], not TagFilter[])
  if (isArgArray(method.args)) {
    errors.push(...checkVarRefsInArgs(method.args, scope, outputScope));
  }

  // 6. Contextual requirements
  errors.push(...checkContextual(method.name, method.args, ctx, method.pos));

  // Update context
  if (phaseNum >= ctx.lastPhase) {
    ctx.lastPhase = phaseNum;
    ctx.lastPhaseName = phaseName;
  }
  ctx.lastMethodName = method.name;
  if (method.name === "around" || method.name === "near") ctx.hasAround = true;
  if (method.name === "limit") ctx.hasLimit = true;
  if (isOutputMode(method.name)) ctx.outputModeCount++;

  return errors;
}

// ── Method compatibility hints ───────────────────────────────────────

function simplifyHint(method: string, inputType: PqlType): string | undefined {
  if (method === "simplify" && inputType === "PointSet")
    return "remove `.simplify()`, or search for `way` or `relation` types";
  return undefined;
}

// ── Spatial argument checking ────────────────────────────────────────

const SPATIAL_WITH_GEOMETRY = new Set([
  "within",
  "not_within",
  "around",
  "near",
  "intersects",
  "not_intersects",
  "contains",
  "not_contains",
  "crosses",
  "touches",
]);

function checkSpatialArgs(
  methodName: string,
  args: Arg[] | TagFilter[],
  pos: Pos,
  scope: Scope,
  outputScope: Scope
): TypeCheckError[] {
  if (!SPATIAL_WITH_GEOMETRY.has(methodName)) return [];
  if (!isArgArray(args)) return [];

  const validTypes = validSpatialArgTypes(methodName);
  const errors: TypeCheckError[] = [];

  for (const expr of extractGeometryExprs(args)) {
    const argType = inferArgType(expr, scope, outputScope);
    if (argType !== null && !validTypes.includes(argType)) {
      errors.push({
        line: pos.line,
        col: pos.col,
        message: `\`.${methodName}()\` requires ${validTypes.join(", ")} but got ${argType}`,
        hint: spatialHint(methodName, argType),
        severity: "error",
      });
    }
  }

  return errors;
}

function extractGeometryExprs(args: Arg[]): Expr[] {
  const exprs: Expr[] = [];
  for (const arg of args) {
    if (arg.type === "kwarg" && arg.name === "geometry") {
      exprs.push(arg.value);
    } else if (arg.type === "posarg") {
      const v = arg.value;
      if (v.kind !== "number" && v.kind !== "string" && v.kind !== "identifier" && v.kind !== "atom" && v.kind !== "bool") {
        exprs.push(v);
      }
    }
  }
  return exprs;
}

const ARG_TYPE_BY_KIND: Partial<Record<Expr["kind"], PqlType>> = {
  point: "Point",
  linestring: "LineString",
  polygon: "Polygon",
  bbox: "Polygon",
  circle: "Polygon",
  area: "Area",
};

function inferArgType(expr: Expr, scope: Scope, outputScope: Scope): PqlType | null {
  if (expr.kind === "var_ref") {
    const info = scope.get(expr.name);
    return info?.type ?? null;
  }
  if (expr.kind === "output_ref") {
    const info = outputScope.get(`$$.${expr.name}`);
    return info?.type ?? null;
  }
  if (expr.kind === "computation") {
    return computationType(expr.name);
  }
  return ARG_TYPE_BY_KIND[expr.kind] ?? null;
}

function spatialHint(method: string, argType: PqlType): string | undefined {
  if (method === "within" && argType === "Route")
    return "use `.around(distance: 200, geometry: $var)` to search near the route";
  if (method === "within")
    return "use an `area()`, `polygon()`, or `isochrone()` variable";
  if (method === "crosses")
    return "`.crosses()` requires a LineString or Route geometry";
  return undefined;
}

// ── Var ref checking in args ─────────────────────────────────────────

function checkVarRefsInArgs(args: Arg[], scope: Scope, outputScope: Scope): TypeCheckError[] {
  const errors: TypeCheckError[] = [];
  for (const arg of args) {
    const expr = arg.type === "posarg" ? arg.value : arg.value;
    if (expr.kind === "var_ref" && !scope.has(expr.name)) {
      errors.push({
        line: expr.pos.line,
        col: expr.pos.col,
        message: `undefined variable \`${expr.name}\``,
        hint: `define it first: ${expr.name} = <expression>;`,
        severity: "error",
      });
    }
    if (expr.kind === "output_ref") {
      const key = `$$.${expr.name}`;
      if (!outputScope.has(key)) {
        errors.push({
          line: expr.pos.line,
          col: expr.pos.col,
          message: `undefined output variable \`${key}\``,
          hint: `assign it first: ${key} = <expression>;`,
          severity: "error",
        });
      }
    }
  }
  return errors;
}

// ── Contextual requirements ──────────────────────────────────────────

function checkContextual(
  methodName: string,
  args: Arg[] | TagFilter[],
  ctx: ChainContext,
  pos: Pos
): TypeCheckError[] {
  if (methodName === "sort" && isArgArray(args) && sortByDistance(args) && !ctx.hasAround) {
    return [
      {
        line: pos.line,
        col: pos.col,
        message: "`.sort(distance)` requires a spatial reference point",
        hint: "use `.around(...)` or `.near(...)` before `.sort(distance)`, or sort by `name` or `osm_id`",
        severity: "error",
      },
    ];
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
    ];
  }

  return [];
}

function sortByDistance(args: Arg[]): boolean {
  return args.some((arg) => {
    if (arg.type === "posarg" && arg.value.kind === "identifier" && arg.value.name === "distance")
      return true;
    if (arg.type === "kwarg" && arg.name === "by" && arg.value.kind === "identifier" && arg.value.name === "distance")
      return true;
    if (arg.type === "posarg" && arg.value.kind === "atom" && arg.value.value === "distance")
      return true;
    if (arg.type === "kwarg" && arg.name === "by" && arg.value.kind === "atom" && arg.value.value === "distance")
      return true;
    return false;
  });
}

// ── Type guard ───────────────────────────────────────────────────────

function isArgArray(args: Arg[] | TagFilter[]): args is Arg[] {
  if (args.length === 0) return true;
  const first = args[0]!;
  return "type" in first && (first.type === "posarg" || first.type === "kwarg");
}

// ── Exported helpers for LSP features ────────────────────────────────

export function inferExprType(expr: Expr, scope: Scope, outputScope?: Scope): PqlType {
  return checkExpr(expr, scope, outputScope ?? new Map()).type;
}

export function getExprAtPosition(
  ast: Statement[],
  line: number,
  col: number
): { expr: Expr | null; scope: Scope; outputScope: Scope } {
  const scope: Scope = new Map();
  const outputScope: Scope = new Map();
  // Build scope up to the given position
  for (const stmt of ast) {
    if (stmt.pos.line < line || (stmt.pos.line === line && stmt.pos.col < col)) {
      if (stmt.kind === "var_assign") {
        const type = checkExpr(stmt.expr, scope, outputScope).type;
        scope.set(stmt.name, { type, line: stmt.pos.line, col: stmt.pos.col, expr: stmt.expr });
      } else if (stmt.kind === "output" && stmt.name !== null) {
        const type = checkExpr(stmt.expr, scope, outputScope).type;
        const key = `$$.${stmt.name}`;
        outputScope.set(key, { type, line: stmt.pos.line, col: stmt.pos.col, expr: stmt.expr });
      }
    }
  }
  return { expr: null, scope, outputScope };
}
