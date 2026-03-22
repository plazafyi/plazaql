"use strict";
// PlazaQL diagnostic provider
Object.defineProperty(exports, "__esModule", { value: true });
exports.getDiagnostics = getDiagnostics;
const parser_js_1 = require("./parser.js");
const type_checker_js_1 = require("./type-checker.js");
function getDiagnostics(source) {
    const { ast, errors: parseErrors } = (0, parser_js_1.parse)(source);
    const diagnostics = [];
    for (const err of parseErrors) {
        diagnostics.push({
            line: err.line,
            col: err.col,
            message: err.message,
            severity: "error",
            source: "parser",
        });
    }
    // Only run type checker if we have a valid AST
    if (ast.length > 0) {
        const { errors: typeErrors } = (0, type_checker_js_1.typeCheck)(ast);
        for (const err of typeErrors) {
            diagnostics.push({
                line: err.line,
                col: err.col,
                message: err.message,
                hint: err.hint,
                severity: err.severity,
                source: "type-checker",
            });
        }
    }
    return diagnostics.sort((a, b) => a.line - b.line || a.col - b.col);
}
//# sourceMappingURL=diagnostics.js.map