"use strict";
// PlazaQL formatter — ported from Plaza.PlazaQL.Formatter
Object.defineProperty(exports, "__esModule", { value: true });
exports.formatDocument = formatDocument;
const parser_js_1 = require("./parser.js");
const MAX_LINE_LENGTH = 80;
function formatDocument(source) {
    const { ast, errors } = (0, parser_js_1.parse)(source);
    if (errors.length > 0)
        return null; // don't format if there are parse errors
    if (ast.length === 0)
        return null;
    return formatAst(ast);
}
function formatAst(ast) {
    return ast.map(formatStatement).join("\n\n") + "\n";
}
function formatStatement(stmt) {
    switch (stmt.kind) {
        case "settings": {
            const pairs = stmt.pairs.map(formatSettingPair).join(", ");
            return `[${pairs}]`;
        }
        case "var_assign":
            return `${stmt.name} = ${formatExpr(stmt.expr)};`;
        case "output": {
            const lhs = stmt.name ? `$$.${stmt.name}` : "$$";
            return `${lhs} = ${formatExpr(stmt.expr)};`;
        }
    }
}
function formatSettingPair(pair) {
    if (typeof pair.value === "string") {
        return `${pair.key}: ${formatStringLiteral(pair.value)}`;
    }
    return `${pair.key}: ${pair.value}`;
}
function formatExpr(expr) {
    switch (expr.kind) {
        case "search": {
            const head = formatSearchHead(expr.elementType, expr.filters);
            return formatWithMethods(head, expr.methods);
        }
        case "chain": {
            const { base, methods } = flattenChain(expr);
            let baseStr = formatExpr(base);
            if (isSetOp(base))
                baseStr = `(${baseStr})`;
            return formatWithMethods(baseStr, methods);
        }
        case "area":
            return `area(${expr.filters.map(formatTagFilter).join(", ")})`;
        case "computation":
            return `${expr.name}(${formatArgList(expr.args)})`;
        case "point":
            if (expr.lat !== null && expr.lng !== null) {
                return `point(${formatNumber(expr.lat)}, ${formatNumber(expr.lng)})`;
            }
            return `point(${formatArgList(expr.args)})`;
        case "bbox":
            if (expr.s !== null && expr.w !== null && expr.n !== null && expr.e !== null) {
                return `bbox(${formatNumber(expr.s)}, ${formatNumber(expr.w)}, ${formatNumber(expr.n)}, ${formatNumber(expr.e)})`;
            }
            return `bbox(${formatArgList(expr.args)})`;
        case "linestring":
        case "polygon":
        case "circle":
            return `${expr.kind}(${expr.items.map(formatExpr).join(", ")})`;
        case "list":
            return `[${expr.items.map(formatExpr).join(", ")}]`;
        case "arrow_chain":
            return expr.items.map(formatExpr).join(" -> ");
        case "union":
            return `${formatExpr(expr.left)} + ${formatExpr(expr.right)}`;
        case "difference":
            return `${formatExpr(expr.left)} - ${formatExpr(expr.right)}`;
        case "var_ref":
            return expr.name;
        case "number":
            return formatNumber(expr.value);
        case "string":
            return formatStringLiteral(expr.value);
        case "bool":
            return String(expr.value);
        case "atom":
            return `:${expr.value}`;
        case "identifier":
            return expr.name;
    }
}
function formatSearchHead(elementType, filters) {
    const parts = [];
    if (elementType)
        parts.push(elementType);
    parts.push(...filters.map(formatTagFilter));
    return `search(${parts.join(", ")})`;
}
function formatTagFilter(filter) {
    switch (filter.op) {
        case "eq":
            return `${filter.key}: "${escapeString(filter.value)}"`;
        case "neq":
            return `${filter.key}: !"${escapeString(filter.value)}"`;
        case "regex":
            return `${filter.key}: ~"${escapeString(filter.value)}"`;
        case "regex_i":
            return `${filter.key}: ~i"${escapeString(filter.value)}"`;
        case "not_regex":
            return `${filter.key}: !~"${escapeString(filter.value)}"`;
        case "exists":
            return `${filter.key}: *`;
        case "not_exists":
            return `${filter.key}: !*`;
    }
}
function formatWithMethods(baseStr, methods) {
    if (methods.length === 0)
        return baseStr;
    const dotted = methods.map((m) => `.${formatMethod(m)}`);
    const singleLine = baseStr + dotted.join("");
    if (singleLine.length <= MAX_LINE_LENGTH) {
        return singleLine;
    }
    return baseStr + "\n" + dotted.map((d) => `  ${d}`).join("\n");
}
function formatMethod(method) {
    if (method.name === "filter") {
        const filters = method.args;
        return `filter(${filters.map(formatTagFilter).join(", ")})`;
    }
    const args = method.args;
    return `${method.name}(${formatArgList(args)})`;
}
function formatArgList(args) {
    return args.map(formatArg).join(", ");
}
function formatArg(arg) {
    if (arg.type === "kwarg") {
        return `${arg.name}: ${formatExpr(arg.value)}`;
    }
    return formatExpr(arg.value);
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
function isSetOp(expr) {
    return expr.kind === "union" || expr.kind === "difference";
}
function formatNumber(value) {
    return String(value);
}
function formatStringLiteral(value) {
    return `"${escapeString(value)}"`;
}
function escapeString(str) {
    return str
        .replace(/\\/g, "\\\\")
        .replace(/"/g, '\\"')
        .replace(/\n/g, "\\n")
        .replace(/\t/g, "\\t");
}
//# sourceMappingURL=formatter.js.map