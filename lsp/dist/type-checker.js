"use strict";
// PlazaQL type checker — ported from Plaza.PlazaQL.TypeChecker
Object.defineProperty(exports, "__esModule", { value: true });
exports.typeCheck = typeCheck;
exports.inferExprType = inferExprType;
exports.getExprAtPosition = getExprAtPosition;
const types_js_1 = require("./types.js");
function typeCheck(ast) {
    const scope = new Map();
    const errors = [];
    const stmtTypes = [];
    for (const stmt of ast) {
        const { errs, type } = checkStatement(stmt, scope);
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
        const conflicting = namedOutputs[0];
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
function checkStatement(stmt, scope) {
    switch (stmt.kind) {
        case "settings":
            return { errs: [], type: null };
        case "var_assign": {
            const errs = [];
            if (scope.has(stmt.name)) {
                errs.push({
                    line: stmt.pos.line,
                    col: stmt.pos.col,
                    message: `duplicate variable \`${stmt.name}\``,
                    hint: "choose a different name or remove the earlier definition",
                    severity: "error",
                });
            }
            const { type, errors: exprErrs } = checkExpr(stmt.expr, scope);
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
            const { type, errors: exprErrs } = checkExpr(stmt.expr, scope);
            return { errs: exprErrs, type };
        }
    }
}
function checkExpr(expr, scope) {
    switch (expr.kind) {
        case "search": {
            const baseType = (0, types_js_1.searchBaseType)(expr.elementType);
            const { finalType, errors } = checkMethodChain(expr.methods, baseType, scope);
            return { type: finalType, errors };
        }
        case "area":
            return { type: "Area", errors: [] };
        case "computation": {
            const type = (0, types_js_1.computationType)(expr.name);
            const argErrors = checkVarRefsInArgs(expr.args, scope);
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
        case "chain": {
            return checkChain(expr, scope);
        }
        case "union": {
            const leftR = checkExpr(expr.left, scope);
            const rightR = checkExpr(expr.right, scope);
            const resultType = (0, types_js_1.unionType)(leftR.type, rightR.type);
            return {
                type: resultType,
                errors: [...leftR.errors, ...rightR.errors],
            };
        }
        case "difference": {
            const leftR = checkExpr(expr.left, scope);
            const rightR = checkExpr(expr.right, scope);
            return {
                type: leftR.type,
                errors: [...leftR.errors, ...rightR.errors],
            };
        }
        case "arrow_chain": {
            const itemErrors = expr.items.flatMap((item) => checkExpr(item, scope).errors);
            return { type: "Point", errors: itemErrors };
        }
        case "list": {
            const itemErrors = expr.items.flatMap((item) => checkExpr(item, scope).errors);
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
function checkChain(chain, scope) {
    const { base, methods } = flattenChain(chain);
    const baseResult = checkExpr(base, scope);
    const { finalType, errors: methodErrors } = checkMethodChain(methods, baseResult.type, scope);
    return {
        type: finalType,
        errors: [...baseResult.errors, ...methodErrors],
    };
}
function flattenChain(node) {
    const methods = [];
    let current = node;
    while (current.kind === "chain") {
        methods.unshift(current.method);
        current = current.receiver;
    }
    return { base: current, methods };
}
function checkMethodChain(methods, baseType, scope) {
    const ctx = {
        lastPhase: 0,
        lastPhaseName: "source",
        lastMethodName: null,
        hasAround: false,
        hasLimit: false,
        outputModeCount: 0,
        currentType: baseType,
    };
    const errors = [];
    for (const method of methods) {
        const methodErrs = checkMethod(method, ctx, scope);
        errors.push(...methodErrs);
    }
    return { finalType: ctx.currentType, errors };
}
function checkMethod(method, ctx, scope) {
    const { ordinal: phaseNum, label: phaseName } = (0, types_js_1.methodPhase)(method.name);
    const errors = [];
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
    if ((0, types_js_1.isOutputMode)(method.name) && ctx.outputModeCount > 0) {
        errors.push({
            line: method.pos.line,
            col: method.pos.col,
            message: `multiple output modes — \`.${method.name}()\` conflicts with earlier output mode`,
            hint: "use only one output mode per chain (`.count()`, `.ids()`, `.tags()`, or `.skel()`)",
            severity: "error",
        });
    }
    // 3. Method-type compatibility
    const compat = (0, types_js_1.methodOutputType)(method.name, ctx.currentType);
    if (compat.ok) {
        ctx.currentType = compat.type;
    }
    else {
        errors.push({
            line: method.pos.line,
            col: method.pos.col,
            message: compat.error,
            hint: simplifyHint(method.name, ctx.currentType),
            severity: "error",
        });
    }
    // 4. Spatial arg type checking
    errors.push(...checkSpatialArgs(method.name, method.args, method.pos, scope));
    // 5. Var refs in args (only for Arg[], not TagFilter[])
    if (isArgArray(method.args)) {
        errors.push(...checkVarRefsInArgs(method.args, scope));
    }
    // 6. Contextual requirements
    errors.push(...checkContextual(method.name, method.args, ctx, method.pos));
    // Update context
    if (phaseNum >= ctx.lastPhase) {
        ctx.lastPhase = phaseNum;
        ctx.lastPhaseName = phaseName;
    }
    ctx.lastMethodName = method.name;
    if (method.name === "around" || method.name === "near")
        ctx.hasAround = true;
    if (method.name === "limit")
        ctx.hasLimit = true;
    if ((0, types_js_1.isOutputMode)(method.name))
        ctx.outputModeCount++;
    return errors;
}
// ── Method compatibility hints ───────────────────────────────────────
function simplifyHint(method, inputType) {
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
function checkSpatialArgs(methodName, args, pos, scope) {
    if (!SPATIAL_WITH_GEOMETRY.has(methodName))
        return [];
    if (!isArgArray(args))
        return [];
    const validTypes = (0, types_js_1.validSpatialArgTypes)(methodName);
    const errors = [];
    for (const expr of extractGeometryExprs(args)) {
        const argType = inferArgType(expr, scope);
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
function extractGeometryExprs(args) {
    const exprs = [];
    for (const arg of args) {
        if (arg.type === "kwarg" && arg.name === "geometry") {
            exprs.push(arg.value);
        }
        else if (arg.type === "posarg") {
            const v = arg.value;
            if (v.kind !== "number" && v.kind !== "string" && v.kind !== "identifier" && v.kind !== "atom" && v.kind !== "bool") {
                exprs.push(v);
            }
        }
    }
    return exprs;
}
const ARG_TYPE_BY_KIND = {
    point: "Point",
    linestring: "LineString",
    polygon: "Polygon",
    bbox: "Polygon",
    circle: "Polygon",
    area: "Area",
};
function inferArgType(expr, scope) {
    if (expr.kind === "var_ref") {
        const info = scope.get(expr.name);
        return info?.type ?? null;
    }
    if (expr.kind === "computation") {
        return (0, types_js_1.computationType)(expr.name);
    }
    return ARG_TYPE_BY_KIND[expr.kind] ?? null;
}
function spatialHint(method, argType) {
    if (method === "within" && argType === "Route")
        return "use `.around(distance: 200, geometry: $var)` to search near the route";
    if (method === "within")
        return "use an `area()`, `polygon()`, or `isochrone()` variable";
    if (method === "crosses")
        return "`.crosses()` requires a LineString or Route geometry";
    return undefined;
}
// ── Var ref checking in args ─────────────────────────────────────────
function checkVarRefsInArgs(args, scope) {
    const errors = [];
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
    }
    return errors;
}
// ── Contextual requirements ──────────────────────────────────────────
function checkContextual(methodName, args, ctx, pos) {
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
function sortByDistance(args) {
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
function isArgArray(args) {
    if (args.length === 0)
        return true;
    const first = args[0];
    return "type" in first && (first.type === "posarg" || first.type === "kwarg");
}
// ── Exported helpers for LSP features ────────────────────────────────
function inferExprType(expr, scope) {
    return checkExpr(expr, scope).type;
}
function getExprAtPosition(ast, line, col) {
    const scope = new Map();
    // Build scope up to the given position
    for (const stmt of ast) {
        if (stmt.kind === "var_assign") {
            if (stmt.pos.line < line || (stmt.pos.line === line && stmt.pos.col < col)) {
                const type = checkExpr(stmt.expr, scope).type;
                scope.set(stmt.name, { type, line: stmt.pos.line, col: stmt.pos.col, expr: stmt.expr });
            }
        }
    }
    return { expr: null, scope };
}
//# sourceMappingURL=type-checker.js.map