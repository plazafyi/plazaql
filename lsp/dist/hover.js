"use strict";
// PlazaQL hover provider
Object.defineProperty(exports, "__esModule", { value: true });
exports.getHover = getHover;
const parser_js_1 = require("./parser.js");
const type_checker_js_1 = require("./type-checker.js");
const types_js_1 = require("./types.js");
function getHover(source, line, col) {
    const { ast } = (0, parser_js_1.parse)(source);
    const { scope } = (0, type_checker_js_1.typeCheck)(ast);
    // Find what's at the cursor position
    const token = getTokenAtPosition(source, line, col);
    if (!token)
        return null;
    // Variable hover
    if (token.startsWith("$")) {
        return getVarHover(token, scope, source, ast);
    }
    // Method hover (after a dot)
    const methodInfo = types_js_1.METHOD_CATALOG.find((m) => m.name === token);
    if (methodInfo) {
        return {
            contents: [
                `${methodInfo.signature} → same type`,
                `  ${methodInfo.description}`,
                `  Phase ${methodInfo.ordinal} (${methodInfo.phase})`,
            ].join("\n"),
        };
    }
    // Function hover
    const funcSig = types_js_1.FUNCTION_SIGNATURES[token];
    if (funcSig) {
        const params = funcSig.params
            .map((p) => `${p.name}${p.optional ? "?" : ""}: ${p.type}`)
            .join(", ");
        return {
            contents: [
                `${funcSig.name}(${params}) → ${funcSig.returnType}`,
                `  ${funcSig.description}`,
            ].join("\n"),
        };
    }
    // Element type hover
    const elementDescriptions = {
        node: "OSM Node — a single point (lat/lng). Examples: shops, restaurants, bus stops.",
        way: "OSM Way — an ordered list of nodes forming a line or polygon. Examples: roads, buildings, rivers.",
        relation: "OSM Relation — a group of nodes/ways with roles. Examples: bus routes, admin boundaries.",
        nwr: "Any element type (node, way, or relation).",
        nw: "Node or Way.",
        nr: "Node or Relation.",
        wr: "Way or Relation.",
    };
    const elemDesc = elementDescriptions[token];
    if (elemDesc) {
        return { contents: elemDesc };
    }
    return null;
}
function getVarHover(name, scope, source, ast) {
    const info = scope.get(name);
    if (!info)
        return null;
    // Find the source text of the definition expression
    let exprText = "";
    for (const stmt of ast) {
        if (stmt.kind === "var_assign" && stmt.name === name) {
            // Extract the expression text from source
            const lines = source.split("\n");
            const line = lines[stmt.pos.line - 1] ?? "";
            const eqIdx = line.indexOf("=", stmt.pos.col - 1);
            if (eqIdx >= 0) {
                exprText = line.slice(eqIdx + 1).replace(/;\s*$/, "").trim();
            }
            break;
        }
    }
    const parts = [`${name} :: ${info.type}`, `  Defined at line ${info.line}`];
    if (exprText) {
        parts.push(`  = ${exprText}`);
    }
    return { contents: parts.join("\n") };
}
function getTokenAtPosition(source, line, col) {
    const lines = source.split("\n");
    const currentLine = lines[line - 1];
    if (!currentLine)
        return null;
    const idx = col - 1;
    // Check for $variable
    if (currentLine[idx] === "$" || (idx > 0 && currentLine[idx - 1] === "$")) {
        let start = idx;
        if (currentLine[start] === "$")
            start++;
        else {
            // Back up to find $
            let s = idx;
            while (s > 0 && isIdentChar(currentLine[s - 1]))
                s--;
            if (s > 0 && currentLine[s - 1] === "$") {
                start = s;
                const end = findIdentEnd(currentLine, start);
                return "$" + currentLine.slice(start, end);
            }
        }
        const end = findIdentEnd(currentLine, start);
        return "$" + currentLine.slice(start, end);
    }
    // Find identifier at position
    let start = idx;
    while (start > 0 && isIdentChar(currentLine[start - 1]))
        start--;
    let end = idx;
    while (end < currentLine.length && isIdentChar(currentLine[end]))
        end++;
    if (start === end)
        return null;
    // Check if preceded by $ (for variable references)
    if (start > 0 && currentLine[start - 1] === "$") {
        return "$" + currentLine.slice(start, end);
    }
    return currentLine.slice(start, end);
}
function findIdentEnd(line, start) {
    let end = start;
    while (end < line.length && isIdentChar(line[end]))
        end++;
    return end;
}
function isIdentChar(ch) {
    return ((ch >= "a" && ch <= "z") ||
        (ch >= "A" && ch <= "Z") ||
        (ch >= "0" && ch <= "9") ||
        ch === "_");
}
//# sourceMappingURL=hover.js.map