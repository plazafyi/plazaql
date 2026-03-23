// PlazaQL hover provider

import { parse } from "./parser.js";
import { typeCheck } from "./type-checker.js";
import type { Scope } from "./type-checker.js";
import type { Statement } from "./types.js";
import { METHOD_CATALOG, FUNCTION_SIGNATURES } from "./types.js";

export interface HoverResult {
  contents: string;
  range?: { startLine: number; startCol: number; endLine: number; endCol: number };
}

export function getHover(
  source: string,
  line: number,
  col: number
): HoverResult | null {
  const { ast } = parse(source);
  const { scope } = typeCheck(ast);

  // Build output scope from named outputs
  const outputScope: Map<string, { type: string; line: number }> = new Map();
  for (const stmt of ast) {
    if (stmt.kind === "output" && stmt.name !== null) {
      const stmtIdx = ast.indexOf(stmt);
      const stmtType = typeCheck(ast).stmtTypes[stmtIdx];
      outputScope.set(`$$.${stmt.name}`, {
        type: stmtType ?? "unknown",
        line: stmt.pos.line,
      });
    }
  }

  // Find what's at the cursor position
  const token = getTokenAtPosition(source, line, col);
  if (!token) return null;

  // Output variable hover ($$.name)
  if (token.startsWith("$$.")) {
    const info = outputScope.get(token);
    if (info) {
      return {
        contents: [
          `${token} :: ${info.type}`,
          `  Named output defined at line ${info.line}`,
        ].join("\n"),
      };
    }
    return {
      contents: `${token} — undefined output variable`,
    };
  }

  // Variable hover
  if (token.startsWith("$")) {
    return getVarHover(token, scope, source, ast);
  }

  // Method hover (after a dot)
  const methodInfo = METHOD_CATALOG.find((m) => m.name === token);
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
  const funcSig = FUNCTION_SIGNATURES[token];
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
  const elementDescriptions: Record<string, string> = {
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

function getVarHover(
  name: string,
  scope: Scope,
  source: string,
  ast: Statement[]
): HoverResult | null {
  const info = scope.get(name);
  if (!info) return null;

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

function getTokenAtPosition(
  source: string,
  line: number,
  col: number
): string | null {
  const lines = source.split("\n");
  const currentLine = lines[line - 1];
  if (!currentLine) return null;

  const idx = col - 1;

  // Check for $$.name output reference
  // Find if cursor is within a $$.name token by scanning backward
  {
    let s = idx;
    // Move backward through identifier chars
    while (s > 0 && isIdentChar(currentLine[s - 1]!)) s--;
    // Check for preceding "$$."
    if (s >= 3 && currentLine[s - 1] === "." && currentLine[s - 2] === "$" && currentLine[s - 3] === "$") {
      const end = findIdentEnd(currentLine, s);
      const name = currentLine.slice(s, end);
      if (name) return "$$." + name;
    }
    // Cursor on the $$ or $$.
    if (currentLine[idx] === "$" && currentLine[idx + 1] === "$") {
      if (currentLine[idx + 2] === ".") {
        const nameStart = idx + 3;
        const end = findIdentEnd(currentLine, nameStart);
        const name = currentLine.slice(nameStart, end);
        if (name) return "$$." + name;
      }
    }
  }

  // Check for $variable
  if (currentLine[idx] === "$" || (idx > 0 && currentLine[idx - 1] === "$")) {
    let start = idx;
    if (currentLine[start] === "$") start++;
    else {
      // Back up to find $
      let s = idx;
      while (s > 0 && isIdentChar(currentLine[s - 1]!)) s--;
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
  while (start > 0 && isIdentChar(currentLine[start - 1]!)) start--;
  let end = idx;
  while (end < currentLine.length && isIdentChar(currentLine[end]!)) end++;

  if (start === end) return null;

  // Check if preceded by $ (for variable references)
  if (start > 0 && currentLine[start - 1] === "$") {
    return "$" + currentLine.slice(start, end);
  }

  return currentLine.slice(start, end);
}

function findIdentEnd(line: string, start: number): number {
  let end = start;
  while (end < line.length && isIdentChar(line[end]!)) end++;
  return end;
}

function isIdentChar(ch: string): boolean {
  return (
    (ch >= "a" && ch <= "z") ||
    (ch >= "A" && ch <= "Z") ||
    (ch >= "0" && ch <= "9") ||
    ch === "_"
  );
}
