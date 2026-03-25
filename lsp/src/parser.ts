// PlazaQL parser — tree-sitter WASM + CST→AST transformation

import { join } from "node:path"
import {
  type Node as SyntaxNode,
  Language as TreeSitterLanguage,
  Parser as TreeSitterParser,
} from "web-tree-sitter"

import type {
  Arg,
  AtomNode,
  BareOutputNode,
  BboxNode,
  BoolNode,
  BoundaryNode,
  ChainNode,
  ComputationName,
  ComputationNode,
  DifferenceNode,
  ElementType,
  Expr,
  GeometryNode,
  IdentifierNode,
  IntersectionNode,
  ListNode,
  MethodNode,
  NumberNode,
  OutputNode,
  OutputRefNode,
  PointNode,
  Pos,
  SearchNode,
  SettingsNode,
  Statement,
  StringNode,
  TagFilter,
  UnionNode,
  VarAssignNode,
  VarRefNode,
} from "./types.js"

// ── Diagnostic ───────────────────────────────────────────────────────

export interface ParseError {
  line: number
  col: number
  message: string
}

export interface ParseResult {
  ast: Statement[]
  errors: ParseError[]
}

// ── Tree-sitter initialization ───────────────────────────────────────

let parserInstance: TreeSitterParser | null = null
let initPromise: Promise<void> | null = null

async function ensureParser(): Promise<TreeSitterParser> {
  if (parserInstance) {
    return parserInstance
  }
  if (!initPromise) {
    initPromise = (async () => {
      await TreeSitterParser.init()
      const wasmPath = join(__dirname, "tree-sitter-plazaql.wasm")
      const lang = await TreeSitterLanguage.load(wasmPath)
      const p = new TreeSitterParser()
      p.setLanguage(lang)
      parserInstance = p
    })()
  }
  await initPromise
  if (!parserInstance) {
    throw new Error("Parser failed to initialize")
  }
  return parserInstance
}

// ── Settings block pre-processor ─────────────────────────────────────
// The tree-sitter grammar uses #directive() syntax, not [settings] syntax.
// We parse [key: value, ...] settings blocks manually and strip them from
// the source before handing to tree-sitter.

interface SettingsParseResult {
  settings: SettingsNode[]
  strippedSource: string
  lineOffsets: number[] // maps stripped line index -> original line number (1-based)
}

function preProcessSettings(source: string): SettingsParseResult {
  const lines = source.split("\n")
  const settings: SettingsNode[] = []
  const keptLines: string[] = []
  const lineOffsets: number[] = []

  let i = 0
  while (i < lines.length) {
    const line = lines[i] as string
    const trimmed = line.trim()

    // Check for settings block: starts with [ and contains key: value pairs
    if (trimmed.startsWith("[") && trimmed.includes(":")) {
      const settingsNode = tryParseSettingsLine(trimmed, i + 1)
      if (settingsNode) {
        settings.push(settingsNode)
        // Replace with blank line to preserve line count
        keptLines.push("")
        lineOffsets.push(i + 1)
        i++
        continue
      }
    }

    keptLines.push(line)
    lineOffsets.push(i + 1)
    i++
  }

  return {
    settings,
    strippedSource: keptLines.join("\n"),
    lineOffsets,
  }
}

function tryParseSettingsLine(
  trimmed: string,
  lineNum: number,
): SettingsNode | null {
  // Match [key: value, key: value, ...]
  if (!trimmed.startsWith("[")) {
    return null
  }
  const closeBracket = trimmed.lastIndexOf("]")
  if (closeBracket < 0) {
    return null
  }

  const inner = trimmed.slice(1, closeBracket).trim()
  if (!inner) {
    return null
  }

  const pairs: Array<{ key: string; value: string | number | boolean }> = []
  const parts = splitSettingsPairs(inner)

  for (const part of parts) {
    const colonIdx = part.indexOf(":")
    if (colonIdx < 0) {
      return null
    }
    const key = part.slice(0, colonIdx).trim()
    const rawValue = part.slice(colonIdx + 1).trim()
    if (!key || !rawValue) {
      return null
    }
    if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(key)) {
      return null
    }

    const value = parseSettingValue(rawValue)
    if (value === null) {
      return null
    }
    pairs.push({ key, value })
  }

  if (pairs.length === 0) {
    return null
  }
  return { kind: "settings", pairs, pos: { line: lineNum, col: 1 } }
}

function splitSettingsPairs(inner: string): string[] {
  const parts: string[] = []
  let current = ""
  let inString = false
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i] as string
    if (ch === '"') {
      if (i > 0 && inner[i - 1] === "\\") {
        current += ch
      } else {
        inString = !inString
        current += ch
      }
    } else if (ch === "," && !inString) {
      parts.push(current)
      current = ""
    } else {
      current += ch
    }
  }
  if (current.trim()) {
    parts.push(current)
  }
  return parts
}

function parseSettingValue(raw: string): string | number | boolean | null {
  if (raw === "true") {
    return true
  }
  if (raw === "false") {
    return false
  }
  if (raw.startsWith('"') && raw.endsWith('"')) {
    return raw.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, "\\")
  }
  const num = Number(raw)
  if (!Number.isNaN(num) && raw !== "") {
    return num
  }
  return null
}

// ── Position helper ──────────────────────────────────────────────────

function pos(node: SyntaxNode): Pos {
  return {
    line: node.startPosition.row + 1,
    col: node.startPosition.column + 1,
  }
}

// ── String helpers ───────────────────────────────────────────────────

function unquoteString(text: string): string {
  // Remove surrounding quotes and handle escape sequences
  if (text.startsWith('"') && text.endsWith('"')) {
    const inner = text.slice(1, -1)
    let result = ""
    for (let i = 0; i < inner.length; i++) {
      if (inner[i] === "\\" && i + 1 < inner.length) {
        i++
        switch (inner[i]) {
          case "n":
            result += "\n"
            break
          case "t":
            result += "\t"
            break
          case '"':
            result += '"'
            break
          case "\\":
            result += "\\"
            break
          default:
            result += inner[i]
            break
        }
      } else {
        result += inner[i]
      }
    }
    return result
  }
  return text
}

// ── CST → AST transformation ─────────────────────────────────────────

function collectErrors(
  node: SyntaxNode,
  errors: ParseError[],
  insideMethod = false,
): void {
  if (node.type === "ERROR" || node.isMissing) {
    // Skip ERROR nodes inside method args — these are often recoverable
    // (e.g., .sort(distance) where distance is ambiguous)
    if (insideMethod) {
      return
    }
    const p = pos(node)
    const snippet = node.text.slice(0, 30).trim()
    errors.push({
      line: p.line,
      col: p.col,
      message: node.isMissing
        ? `missing ${node.type}`
        : `unexpected input near: "${snippet}"`,
    })
    return // Don't recurse into ERROR nodes
  }
  const enterMethod = insideMethod || node.type === "method"
  for (let i = 0; i < node.childCount; i++) {
    const childNode = node.child(i)
    if (childNode) {
      collectErrors(childNode, errors, enterMethod)
    }
  }
}

function transformProgram(root: SyntaxNode): {
  ast: Statement[]
  errors: ParseError[]
} {
  const ast: Statement[] = []
  const errors: ParseError[] = []

  collectErrors(root, errors)

  for (let i = 0; i < root.namedChildCount; i++) {
    const child = root.namedChild(i)
    if (!child) {
      continue
    }
    const stmt = transformStatement(child)
    if (stmt) {
      ast.push(stmt)
    } else if (child.type === "ERROR") {
      // Recover statements and expressions from ERROR nodes
      recoverStatementsFromError(child, ast)
    }
  }

  return { ast, errors }
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: parser helper
function recoverStatementsFromError(
  errorNode: SyntaxNode,
  ast: Statement[],
): void {
  // Try to extract valid statements or expressions from ERROR nodes
  // This handles incomplete code (e.g., "$$ = search().count()." with trailing dot)
  for (let i = 0; i < errorNode.namedChildCount; i++) {
    const child = errorNode.namedChild(i)
    if (!child) {
      continue
    }
    // Try as a statement type first
    const stmt = transformStatement(child)
    if (stmt) {
      ast.push(stmt)
      continue
    }
    // Try as an expression and wrap as output/bare_output
    const expr = transformExpr(child)
    if (expr) {
      // Check if there's an output_ref or output_named_ref sibling before this
      const prevSibling = i > 0 ? errorNode.namedChild(i - 1) : null
      if (prevSibling?.type === "output_ref") {
        ast.push({ kind: "output", name: null, expr, pos: pos(prevSibling) })
      } else if (prevSibling?.type === "output_named_ref") {
        ast.push({
          kind: "output",
          name: prevSibling.text.slice(3),
          expr,
          pos: pos(prevSibling),
        })
      } else {
        ast.push({ kind: "bare_output", expr, pos: pos(child) })
      }
    }
  }
}

function transformStatement(node: SyntaxNode): Statement | null {
  switch (node.type) {
    case "output_assignment":
      return transformOutputAssignment(node)
    case "variable_assignment":
      return transformVarAssignment(node)
    case "bare_statement":
      return transformBareStatement(node)
    case "directive":
      return transformDirective(node)
    default:
      return null
  }
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: parser helper
function transformDirective(node: SyntaxNode): SettingsNode | null {
  // #settings(key: value, ...) → SettingsNode
  const nameNode = node.childForFieldName("name")
  if (!nameNode) {
    return null
  }

  // Treat any directive as a settings-like node
  const pairs: Array<{ key: string; value: string | number | boolean }> = []

  // Children can be tag_filter_list, filter_expression, or _argument_list
  for (let i = 0; i < node.namedChildCount; i++) {
    const child = node.namedChild(i)
    if (!child) {
      continue
    }
    if (child.type === "tag_filter_list") {
      for (let j = 0; j < child.namedChildCount; j++) {
        const tf = child.namedChild(j)
        if (!tf) {
          continue
        }
        if (tf.type === "tag_filter") {
          const key = tf.childForFieldName("key")?.text ?? ""
          const valueNode = tf.childForFieldName("value")
          if (valueNode) {
            const val = parseDirectiveValue(valueNode)
            if (val !== null) {
              pairs.push({ key, value: val })
            }
          }
        }
      }
    }
  }

  return { kind: "settings", pairs, pos: pos(node) }
}

function parseDirectiveValue(
  node: SyntaxNode,
): string | number | boolean | null {
  switch (node.type) {
    case "number": {
      const text = node.text
      return text.includes(".")
        ? Number.parseFloat(text)
        : Number.parseInt(text, 10)
    }
    case "string":
      return unquoteString(node.text)
    case "boolean":
      return node.text === "true"
    default:
      return node.text
  }
}

function transformOutputAssignment(node: SyntaxNode): OutputNode | null {
  const targetNode = node.childForFieldName("target")
  const valueNode = node.childForFieldName("value")
  if (!targetNode || !valueNode) {
    return null
  }

  let name: string | null = null
  if (targetNode.type === "output_named_ref") {
    // Text is like "$$.cafes", extract the name after "$$."
    name = targetNode.text.slice(3)
  }

  const expr = transformExpr(valueNode)
  if (!expr) {
    return null
  }

  return { kind: "output", name, expr, pos: pos(node) }
}

function transformVarAssignment(node: SyntaxNode): VarAssignNode | null {
  const nameNode = node.childForFieldName("name")
  const valueNode = node.childForFieldName("value")
  if (!nameNode || !valueNode) {
    return null
  }

  const expr = transformExpr(valueNode)
  if (!expr) {
    return null
  }

  return {
    kind: "var_assign",
    name: nameNode.text, // includes "$" prefix
    expr,
    pos: pos(node),
  }
}

function transformBareStatement(node: SyntaxNode): BareOutputNode | null {
  // bare_statement has one named child: the expression
  const exprNode = node.namedChild(0)
  if (!exprNode) {
    return null
  }

  const expr = transformExpr(exprNode)
  if (!expr) {
    return null
  }

  return { kind: "bare_output", expr, pos: pos(node) }
}

// ── Expression transformation ────────────────────────────────────────

function transformExpr(node: SyntaxNode): Expr | null {
  switch (node.type) {
    case "number":
      return transformNumber(node)
    case "string":
      return transformString(node)
    case "boolean":
      return transformBool(node)
    case "atom":
      return transformAtom(node)
    case "identifier":
    case "bare_identifier":
      return transformIdentifier(node)
    case "variable_ref":
      return transformVarRef(node)
    case "output_ref":
      return transformOutputRef(node)
    case "output_named_ref":
      return transformOutputNamedRef(node)
    case "point_constructor":
      return transformPoint(node)
    case "bbox_constructor":
      return transformBbox(node)
    case "linestring_constructor":
      return transformGeometry("linestring", node)
    case "polygon_constructor":
      return transformGeometry("polygon", node)
    case "circle_constructor":
      return transformGeometry("circle", node)
    case "search_expression":
      return transformSearch(node)
    case "boundary_expression":
      return transformBoundary(node)
    case "computation":
      return transformComputation(node)
    case "method_call":
      return transformMethodCall(node)
    case "union_expression":
      return transformUnion(node)
    case "difference_expression":
      return transformDifference(node)
    case "intersection_expression":
      return transformIntersection(node)
    case "list_literal":
      return transformList(node)
    case "parenthesized_expression":
      return transformParenthesized(node)
    case "filter_function_call":
      // In the old parser, these are treated as identifiers
      return transformFilterFunctionCall(node)
    default:
      return null
  }
}

function transformNumber(node: SyntaxNode): NumberNode {
  const text = node.text
  const value = text.includes(".")
    ? Number.parseFloat(text)
    : Number.parseInt(text, 10)
  return { kind: "number", value, pos: pos(node) }
}

function transformString(node: SyntaxNode): StringNode {
  return { kind: "string", value: unquoteString(node.text), pos: pos(node) }
}

function transformBool(node: SyntaxNode): BoolNode {
  return { kind: "bool", value: node.text === "true", pos: pos(node) }
}

function transformAtom(node: SyntaxNode): AtomNode {
  // atom has child identifier
  const identNode = node.namedChild(0)
  return { kind: "atom", value: identNode?.text ?? "", pos: pos(node) }
}

function transformIdentifier(node: SyntaxNode): IdentifierNode {
  // bare_identifier wraps an identifier
  const name =
    node.type === "bare_identifier"
      ? (node.namedChild(0)?.text ?? node.text)
      : node.text
  return { kind: "identifier", name, pos: pos(node) }
}

function transformVarRef(node: SyntaxNode): VarRefNode {
  return { kind: "var_ref", name: node.text, pos: pos(node) }
}

function transformOutputRef(node: SyntaxNode): OutputRefNode {
  return { kind: "output_ref", name: "", pos: pos(node) }
}

function transformOutputNamedRef(node: SyntaxNode): OutputRefNode {
  // Text is "$$.name"
  const name = node.text.slice(3)
  return { kind: "output_ref", name, pos: pos(node) }
}

function transformPoint(node: SyntaxNode): PointNode {
  const args = collectArgs(node)
  const { lat, lng } = extractLatLng(args)
  return { kind: "point", lat, lng, args, pos: pos(node) }
}

function transformBbox(node: SyntaxNode): BboxNode {
  const args = collectArgs(node)
  const coords = extractBboxCoords(args)
  return { kind: "bbox", ...coords, args, pos: pos(node) }
}

function transformGeometry(
  name: "linestring" | "polygon" | "circle",
  node: SyntaxNode,
): GeometryNode {
  const items: Expr[] = []
  for (let i = 0; i < node.namedChildCount; i++) {
    const child = node.namedChild(i)
    if (!child) {
      continue
    }
    if (child.type === "keyword_argument") {
      continue
    }
    const expr = transformExpr(child)
    if (expr) {
      items.push(expr)
    }
  }
  return { kind: name, items, pos: pos(node) }
}

function transformSearch(node: SyntaxNode): SearchNode {
  let elementType: ElementType | null = null
  const filters: TagFilter[] = []

  const typeNode = node.childForFieldName("type")
  if (typeNode) {
    elementType = typeNode.text as ElementType
  }

  for (let i = 0; i < node.namedChildCount; i++) {
    const child = node.namedChild(i)
    if (!child) {
      continue
    }
    if (child.type === "tag_filter_list") {
      collectTagFilters(child, filters)
    }
  }

  return { kind: "search", elementType, filters, methods: [], pos: pos(node) }
}

function transformBoundary(node: SyntaxNode): BoundaryNode {
  const filters: TagFilter[] = []
  for (let i = 0; i < node.namedChildCount; i++) {
    const child = node.namedChild(i)
    if (!child) {
      continue
    }
    if (child.type === "tag_filter_list") {
      collectTagFilters(child, filters)
    }
  }
  return { kind: "boundary", filters, pos: pos(node) }
}

function transformComputation(node: SyntaxNode): ComputationNode {
  const nameNode = node.childForFieldName("name")
  const name = (nameNode?.text ?? "") as ComputationName
  const args = collectComputationArgs(node)
  return { kind: "computation", name, args, pos: pos(node) }
}

function transformMethodCall(node: SyntaxNode): Expr | null {
  const receiverNode = node.childForFieldName("receiver")
  const methodNode = node.childForFieldName("method")
  if (!receiverNode || !methodNode) {
    return null
  }

  const receiver = transformExpr(receiverNode)
  if (!receiver) {
    return null
  }

  const method = transformMethod(methodNode)
  if (!method) {
    return null
  }

  // Special handling: if receiver is a search, attach method directly
  // Also walk up the chain: if the ultimate receiver is search, attach all methods
  const searchRoot = findSearchRoot(receiver)
  if (searchRoot) {
    searchRoot.methods.push(method)
    return searchRoot
  }

  return {
    kind: "chain",
    receiver,
    method,
    pos: pos(receiverNode),
  } as ChainNode
}

function findSearchRoot(expr: Expr): SearchNode | null {
  if (expr.kind === "search") {
    return expr
  }
  // If it's a chain whose receiver is a search (methods already attached),
  // we should NOT unwrap - the old parser only attaches to direct search receivers
  return null
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: parser helper
function transformMethod(node: SyntaxNode): MethodNode | null {
  const nameNode = node.childForFieldName("name")
  if (!nameNode) {
    return null
  }
  const name = nameNode.text

  // Collect args: children of method that aren't the name identifier
  const args: (Arg | TagFilter)[] = []
  let hasTagFilters = false

  for (let i = 0; i < node.namedChildCount; i++) {
    const child = node.namedChild(i)
    if (!child) {
      continue
    }
    if (child === nameNode) {
      continue
    }

    if (child.type === "tag_filter" || child.type === "regex_key_filter") {
      hasTagFilters = true
      const tf = transformTagFilter(child)
      if (tf) {
        args.push(tf)
      }
    } else if (child.type === "keyword_argument") {
      const kwarg = transformKwarg(child)
      if (kwarg) {
        args.push(kwarg)
      }
    } else if (child.type === "filter_expression") {
      // filter expressions in method args are positional args
      const expr = transformFilterExprToExpr(child)
      if (expr) {
        args.push({ type: "posarg", value: expr })
      }
    } else if (child.type === "ERROR") {
      // Recover identifiers from ERROR nodes (e.g., .sort(distance))
      const recovered = recoverExprFromError(child)
      if (recovered) {
        args.push({ type: "posarg", value: recovered })
      }
    } else {
      const expr = transformExpr(child)
      if (expr) {
        args.push({ type: "posarg", value: expr })
      }
    }
  }

  if (name === "filter" || hasTagFilters) {
    // filter() method uses TagFilter[] args
    const tagFilters = args.filter((a): a is TagFilter => "op" in a)
    return { kind: "method", name, args: tagFilters, pos: pos(node) }
  }

  const regularArgs = args.filter((a): a is Arg => "type" in a)
  return { kind: "method", name, args: regularArgs, pos: pos(node) }
}

function recoverExprFromError(node: SyntaxNode): Expr | null {
  // Try to recover meaningful expressions from ERROR nodes
  // Common case: .sort(distance) where "distance" is misinterpreted
  const text = node.text.trim()

  // If the error text looks like an identifier, return it as one
  if (/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(text)) {
    return { kind: "identifier", name: text, pos: pos(node) }
  }

  // Try to find named children that are valid expressions
  for (let i = 0; i < node.namedChildCount; i++) {
    const child = node.namedChild(i)
    if (!child) {
      continue
    }
    const expr = transformExpr(child)
    if (expr) {
      return expr
    }
  }

  return null
}

function transformFilterExprToExpr(node: SyntaxNode): Expr | null {
  // A filter_expression wraps a primary which could be a number, string, etc.
  // For method args like .limit(10), the 10 is wrapped in filter_expression
  if (node.namedChildCount === 1) {
    const child = node.namedChild(0)
    if (!child) {
      return null
    }
    return transformExpr(child) ?? transformFilterPrimary(child)
  }
  // For complex filter expressions, try to extract the inner expr
  return transformFilterPrimary(node)
}

function transformFilterPrimary(node: SyntaxNode): Expr | null {
  switch (node.type) {
    case "number":
      return transformNumber(node)
    case "string":
      return transformString(node)
    case "boolean":
      return transformBool(node)
    case "filter_expression":
      if (node.namedChildCount === 1) {
        const inner = node.namedChild(0)
        return inner ? transformFilterPrimary(inner) : null
      }
      return null
    default:
      // Try as regular expr
      return transformExpr(node)
  }
}

function transformUnion(node: SyntaxNode): UnionNode | null {
  const leftNode = node.childForFieldName("left")
  const rightNode = node.childForFieldName("right")
  if (!leftNode || !rightNode) {
    return null
  }
  const left = transformExpr(leftNode)
  const right = transformExpr(rightNode)
  if (!left || !right) {
    return null
  }
  return { kind: "union", left, right, pos: pos(leftNode) }
}

function transformDifference(node: SyntaxNode): DifferenceNode | null {
  const leftNode = node.childForFieldName("left")
  const rightNode = node.childForFieldName("right")
  if (!leftNode || !rightNode) {
    return null
  }
  const left = transformExpr(leftNode)
  const right = transformExpr(rightNode)
  if (!left || !right) {
    return null
  }
  return { kind: "difference", left, right, pos: pos(leftNode) }
}

function transformIntersection(node: SyntaxNode): IntersectionNode | null {
  const leftNode = node.childForFieldName("left")
  const rightNode = node.childForFieldName("right")
  if (!leftNode || !rightNode) {
    return null
  }
  const left = transformExpr(leftNode)
  const right = transformExpr(rightNode)
  if (!left || !right) {
    return null
  }
  return { kind: "intersection", left, right, pos: pos(leftNode) }
}

function transformList(node: SyntaxNode): ListNode {
  const items: Expr[] = []
  for (let i = 0; i < node.namedChildCount; i++) {
    const child = node.namedChild(i)
    if (!child) {
      continue
    }
    const expr = transformExpr(child)
    if (expr) {
      items.push(expr)
    }
  }
  return { kind: "list", items, pos: pos(node) }
}

function transformParenthesized(node: SyntaxNode): Expr | null {
  const inner = node.namedChild(0)
  if (!inner) {
    return null
  }
  return transformExpr(inner)
}

function transformFilterFunctionCall(node: SyntaxNode): IdentifierNode {
  // filter_function_call nodes like distance(...), length(), area()
  // In the old parser context, these are identifiers when used as method args
  return { kind: "identifier", name: node.text, pos: pos(node) }
}

// ── Tag filter transformation ────────────────────────────────────────

function collectTagFilters(listNode: SyntaxNode, filters: TagFilter[]): void {
  for (let i = 0; i < listNode.namedChildCount; i++) {
    const child = listNode.namedChild(i)
    if (!child) {
      continue
    }
    const tf = transformTagFilter(child)
    if (tf) {
      filters.push(tf)
    }
  }
}

function transformTagFilter(node: SyntaxNode): TagFilter | null {
  if (node.type === "tag_filter") {
    const keyNode = node.childForFieldName("key")
    const valueNode = node.childForFieldName("value")
    if (!keyNode) {
      return null
    }

    const key = keyNode.text
    if (!valueNode) {
      return { op: "exists", key }
    }

    return transformTagFilterValue(key, valueNode)
  }
  if (node.type === "regex_key_filter") {
    // Not directly supported in old AST, skip for now
    return null
  }
  return null
}

function transformTagFilterValue(key: string, node: SyntaxNode): TagFilter {
  switch (node.type) {
    case "string":
      return { op: "eq", key, value: unquoteString(node.text) }
    case "tag_neq":
      return {
        op: "neq",
        key,
        value: unquoteString(node.namedChild(0)?.text ?? ""),
      }
    case "tag_regex":
      return {
        op: "regex",
        key,
        value: unquoteString(node.namedChild(0)?.text ?? ""),
      }
    case "tag_regex_i":
      return {
        op: "regex_i",
        key,
        value: unquoteString(node.namedChild(0)?.text ?? ""),
      }
    case "tag_not_regex":
      return {
        op: "not_regex",
        key,
        value: unquoteString(node.namedChild(0)?.text ?? ""),
      }
    case "tag_exists":
      return { op: "exists", key }
    case "tag_not_exists":
      return { op: "not_exists", key }
    case "number":
      return { op: "eq", key, value: node.text }
    default:
      return { op: "exists", key }
  }
}

// ── Argument collection ──────────────────────────────────────────────

function collectArgs(node: SyntaxNode): Arg[] {
  const args: Arg[] = []
  for (let i = 0; i < node.namedChildCount; i++) {
    const child = node.namedChild(i)
    if (!child) {
      continue
    }
    if (child.type === "keyword_argument") {
      const kwarg = transformKwarg(child)
      if (kwarg) {
        args.push(kwarg)
      }
    } else {
      const expr = transformExpr(child)
      if (expr) {
        args.push({ type: "posarg", value: expr })
      }
    }
  }
  return args
}

function collectComputationArgs(node: SyntaxNode): Arg[] {
  const args: Arg[] = []
  // computation field "arguments" can appear multiple times
  for (let i = 0; i < node.namedChildCount; i++) {
    const child = node.namedChild(i)
    if (!child) {
      continue
    }
    if (child.type === "computation_name") {
      continue
    }
    if (child.type === "keyword_argument") {
      const kwarg = transformKwarg(child)
      if (kwarg) {
        args.push(kwarg)
      }
    } else {
      const expr = transformExpr(child)
      if (expr) {
        args.push({ type: "posarg", value: expr })
      }
    }
  }
  return args
}

function transformKwarg(node: SyntaxNode): Arg | null {
  const keyNode = node.childForFieldName("key")
  const valueNode = node.childForFieldName("value")
  if (!keyNode || !valueNode) {
    return null
  }
  const value = transformExpr(valueNode)
  if (!value) {
    return null
  }
  return { type: "kwarg", name: keyNode.text, value }
}

// ── Arg extraction helpers ───────────────────────────────────────────

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: parser helper
function extractLatLng(args: Arg[]): {
  lat: number | null
  lng: number | null
} {
  if (args.length === 2) {
    if (args[0]?.type === "posarg" && args[1]?.type === "posarg") {
      const a = args[0]?.value
      const b = args[1]?.value
      if (a.kind === "number" && b.kind === "number") {
        return { lat: a.value, lng: b.value }
      }
    }
    if (args[0]?.type === "kwarg" && args[1]?.type === "kwarg") {
      const a = args[0]
      const b = args[1]
      let lat: number | null = null
      let lng: number | null = null
      if (a.name === "lat" && a.value.kind === "number") {
        lat = a.value.value
      }
      if (a.name === "lng" && a.value.kind === "number") {
        lng = a.value.value
      }
      if (b.name === "lat" && b.value.kind === "number") {
        lat = b.value.value
      }
      if (b.name === "lng" && b.value.kind === "number") {
        lng = b.value.value
      }
      return { lat, lng }
    }
  }
  return { lat: null, lng: null }
}

function extractBboxCoords(args: Arg[]): {
  s: number | null
  w: number | null
  n: number | null
  e: number | null
} {
  if (
    args.length === 4 &&
    args.every((a) => a.type === "posarg" && a.value.kind === "number")
  ) {
    return {
      s: (args[0]?.value as NumberNode).value,
      w: (args[1]?.value as NumberNode).value,
      n: (args[2]?.value as NumberNode).value,
      e: (args[3]?.value as NumberNode).value,
    }
  }
  return { s: null, w: null, n: null, e: null }
}

// ── Public API ───────────────────────────────────────────────────────

/**
 * Promise that resolves when the WASM parser is ready.
 * Await this before calling parse() for guaranteed results.
 * In the LSP server, call `await parserReady` during initialization.
 */
export const parserReady: Promise<void> = ensureParser().then(() => {
  /* parser initialized */
})

export function parse(source: string): ParseResult {
  if (!parserInstance) {
    // Parser not yet initialized — return empty result
    // This can happen if parse() is called before parserReady resolves
    const { settings } = preProcessSettings(source)
    return { ast: settings, errors: [] }
  }

  // Pre-process settings blocks (tree-sitter grammar uses #directive syntax)
  const { settings, strippedSource } = preProcessSettings(source)

  const tree = parserInstance.parse(strippedSource)
  if (!tree) {
    return { ast: settings, errors: [] }
  }
  const { ast, errors } = transformProgram(tree.rootNode)

  // Prepend settings to AST
  const fullAst: Statement[] = [...settings, ...ast]

  return { ast: fullAst, errors }
}

export { ensureParser }
