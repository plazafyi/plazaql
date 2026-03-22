"use strict";
// PlazaQL completion provider
Object.defineProperty(exports, "__esModule", { value: true });
exports.getCompletions = getCompletions;
const parser_js_1 = require("./parser.js");
const type_checker_js_1 = require("./type-checker.js");
const types_js_1 = require("./types.js");
function getCompletions(source, line, col) {
    const context = analyzeContext(source, line, col);
    switch (context.kind) {
        case "dot":
            return getDotCompletions(source, context.currentType, context.lastPhase);
        case "dollar":
            return getVariableCompletions(source, line);
        case "inside_search":
            return getTagCompletions();
        case "inside_function_params":
            return getParamCompletions(context.functionName);
        case "top_level":
            return getTopLevelCompletions();
        case "after_out":
            return getOutputCompletions();
        default:
            return [];
    }
}
function analyzeContext(source, line, col) {
    const lines = source.split("\n");
    const currentLine = lines[line - 1] ?? "";
    // Include the character at cursor position for trigger character detection
    const textUpTo = currentLine.slice(0, col);
    const trimmed = textUpTo.trimEnd();
    // After "$$" (must check before dot and dollar)
    if (/^\s*\$\$\s*$/.test(textUpTo) || /^\s*\$\$\.$/.test(textUpTo)) {
        return { kind: "after_out" };
    }
    // After "."
    if (trimmed.endsWith(".") || /\.\w*$/.test(textUpTo)) {
        // Try to determine the type and phase of what's before the dot
        const { type, lastPhase } = inferTypeBeforeDot(source, line, col);
        return { kind: "dot", currentType: type, lastPhase };
    }
    // After "$"
    if (/\$\w*$/.test(textUpTo)) {
        return { kind: "dollar" };
    }
    // Inside search(
    if (isInsideCall(textUpTo, "search")) {
        return { kind: "inside_search" };
    }
    // Inside other function params
    for (const fname of Object.keys(types_js_1.FUNCTION_SIGNATURES)) {
        if (isInsideCall(textUpTo, fname)) {
            return { kind: "inside_function_params", functionName: fname };
        }
    }
    // Top-level (start of line or after whitespace)
    if (trimmed === "" || /^\s*$/.test(textUpTo)) {
        return { kind: "top_level" };
    }
    return { kind: "unknown" };
}
function isInsideCall(text, funcName) {
    const idx = text.lastIndexOf(funcName + "(");
    if (idx < 0)
        return false;
    // Count parens after the function call start
    const afterCall = text.slice(idx + funcName.length);
    let depth = 0;
    for (const ch of afterCall) {
        if (ch === "(")
            depth++;
        if (ch === ")")
            depth--;
    }
    return depth > 0;
}
function inferTypeBeforeDot(source, _line, _col) {
    // Parse the full source and check what types variables have
    const { ast } = (0, parser_js_1.parse)(source);
    if (ast.length === 0)
        return { type: null, lastPhase: 0 };
    (0, type_checker_js_1.typeCheck)(ast);
    // Simple heuristic: default to GeoSet
    // A more accurate implementation would track the exact expression at cursor
    const type = "GeoSet";
    const lastPhase = 0;
    return { type, lastPhase };
}
// ── Completion generators ────────────────────────────────────────────
function getDotCompletions(_source, currentType, lastPhase) {
    const items = [];
    for (const m of types_js_1.METHOD_CATALOG) {
        // Skip methods from phases that are already past
        if (m.ordinal > 0 && m.ordinal < lastPhase)
            continue;
        // Skip methods incompatible with current type
        if (currentType && !(0, types_js_1.isChainable)(currentType))
            continue;
        if (currentType === "PointSet" && m.name === "simplify")
            continue;
        items.push({
            label: m.name,
            kind: "method",
            detail: `${m.signature} — Phase ${m.ordinal} (${m.phase})`,
            documentation: m.description,
            insertText: m.name + (m.name === "centroid" || m.name === "count" || m.name === "ids" || m.name === "tags" || m.name === "skel" ? "()" : "("),
            sortText: String(m.ordinal).padStart(2, "0") + m.name,
        });
    }
    return items;
}
function getVariableCompletions(source, _beforeLine) {
    const { ast } = (0, parser_js_1.parse)(source);
    const { scope } = (0, type_checker_js_1.typeCheck)(ast);
    const items = [];
    for (const [name, info] of scope) {
        items.push({
            label: name,
            kind: "variable",
            detail: `:: ${info.type}`,
            documentation: `Defined at line ${info.line}`,
            insertText: name.slice(1), // without the $ since it's already typed
        });
    }
    return items;
}
function getTagCompletions() {
    return types_js_1.COMMON_TAG_KEYS.map((key) => ({
        label: key,
        kind: "tag",
        detail: "OSM tag key",
        insertText: `${key}: `,
    }));
}
function getParamCompletions(functionName) {
    const sig = types_js_1.FUNCTION_SIGNATURES[functionName];
    if (!sig)
        return [];
    return sig.params.map((p) => ({
        label: p.name,
        kind: "param",
        detail: p.type,
        documentation: p.description,
        insertText: p.name.startsWith("...") ? "" : `${p.name}: `,
    }));
}
function getTopLevelCompletions() {
    return [
        {
            label: "search",
            kind: "function",
            detail: "search(...) → GeoSet",
            documentation: "Search for OSM features matching tag filters.",
            insertText: "search(",
        },
        {
            label: "$",
            kind: "keyword",
            detail: "Variable assignment",
            insertText: "$",
        },
        {
            label: "$$",
            kind: "keyword",
            detail: "Output assignment",
            insertText: "$$ = ",
        },
        {
            label: "[",
            kind: "keyword",
            detail: "Settings block",
            insertText: "[",
        },
        {
            label: "area",
            kind: "function",
            detail: "area(...) → Area",
            documentation: "Look up a named boundary or area.",
            insertText: "area(",
        },
        {
            label: "route",
            kind: "function",
            detail: "route(...) → Route",
            insertText: "route(",
        },
        {
            label: "isochrone",
            kind: "function",
            detail: "isochrone(...) → Isochrone",
            insertText: "isochrone(",
        },
        {
            label: "geocode",
            kind: "function",
            detail: 'geocode("address") → PointSet',
            insertText: "geocode(",
        },
    ];
}
function getOutputCompletions() {
    return [
        {
            label: "= ",
            kind: "keyword",
            detail: "Default output",
            insertText: "= ",
        },
        {
            label: ".name = ",
            kind: "keyword",
            detail: "Named output",
            insertText: ".name = ",
        },
    ];
}
//# sourceMappingURL=completions.js.map