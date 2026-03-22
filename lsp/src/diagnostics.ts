// PlazaQL diagnostic provider

import { parse } from "./parser.js";
import { typeCheck } from "./type-checker.js";

export interface Diagnostic {
  line: number;
  col: number;
  endLine?: number;
  endCol?: number;
  message: string;
  hint?: string;
  severity: "error" | "warning";
  source: "parser" | "type-checker";
}

export function getDiagnostics(source: string): Diagnostic[] {
  const { ast, errors: parseErrors } = parse(source);
  const diagnostics: Diagnostic[] = [];

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
    const { errors: typeErrors } = typeCheck(ast);
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
