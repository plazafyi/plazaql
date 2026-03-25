// PlazaQL completion provider

import { OSM_TAG_DATABASE, TAG_KEY_MAP } from "./osm-tags.js"
import { parse } from "./parser.js"
import { inferChainStateAtPosition, typeCheck } from "./type-checker.js"
import type { MethodGroup, PqlType } from "./types.js"
import {
  FUNCTION_SIGNATURES,
  isChainable,
  isTerminal,
  METHOD_CATALOG,
  METHOD_PARAM_VALUES,
  methodPhase,
} from "./types.js"

export interface CompletionItem {
  label: string
  kind:
    | "method"
    | "variable"
    | "keyword"
    | "tag"
    | "function"
    | "param"
    | "value"
    | "operator"
  detail?: string
  documentation?: string
  insertText?: string
  sortText?: string
}

export interface CompletionContext {
  triggerChar: string | null
  line: number
  col: number
}

export function getCompletions(
  source: string,
  line: number,
  col: number,
): CompletionItem[] {
  const context = analyzeContext(source, line, col)

  switch (context.kind) {
    case "dot":
      return getDotCompletions(
        source,
        context.currentType,
        context.lastGroup,
        context.lastOrdinal,
      )
    case "dollar":
      return getVariableCompletions(source, line)
    case "dollar_dollar":
      return getOutputRefCompletions(source)
    case "inside_search":
      switch (context.subContext) {
        case "element_type":
          return [...getElementTypeCompletions(), ...getTagCompletions()]
        case "tag_key":
          return getTagCompletions()
        case "tag_value":
          return getTagValueCompletions(context.tagKey ?? "")
        default:
          return getTagCompletions()
      }
    case "inside_filter":
      switch (context.subContext) {
        case "tag_key":
          return getTagCompletions()
        case "tag_value":
          return getTagValueCompletions(context.tagKey ?? "")
        default:
          return getTagCompletions()
      }
    case "inside_function_params":
      if (context.paramName) {
        return getParamValueCompletions(context.functionName, context.paramName)
      }
      return getParamCompletions(context.functionName)
    case "inside_method_params":
      if (context.paramName) {
        return getMethodParamValueCompletions(
          context.methodName,
          context.paramName,
        )
      }
      return getMethodParamCompletions(context.methodName)
    case "top_level":
      return getTopLevelCompletions()
    case "after_out":
      return getOutputCompletions()
    default:
      return []
  }
}

// ── Context Analysis ─────────────────────────────────────────────────

type AnalyzedContext =
  | {
      kind: "dot"
      currentType: PqlType | null
      lastGroup: MethodGroup
      lastOrdinal: number
    }
  | { kind: "dollar" }
  | { kind: "dollar_dollar" }
  | {
      kind: "inside_search"
      subContext: "element_type" | "tag_key" | "tag_value"
      tagKey?: string
    }
  | {
      kind: "inside_filter"
      subContext: "tag_key" | "tag_value"
      tagKey?: string
    }
  | { kind: "inside_function_params"; functionName: string; paramName?: string }
  | { kind: "inside_method_params"; methodName: string; paramName?: string }
  | { kind: "top_level" }
  | { kind: "after_out" }
  | { kind: "unknown" }

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: parser helper
function analyzeContext(
  source: string,
  line: number,
  col: number,
): AnalyzedContext {
  const lines = source.split("\n")
  const currentLine = lines[line - 1] ?? ""
  const textUpTo = currentLine.slice(0, col)
  const trimmed = textUpTo.trimEnd()

  // After "$$." in value position (not at start of line / not an assignment)
  if (/\$\$\.\w*$/.test(textUpTo) && !/^\s*\$\$\./.test(textUpTo)) {
    return { kind: "dollar_dollar" }
  }

  // After "$$" at start of statement (output assignment context)
  if (/^\s*\$\$\s*$/.test(textUpTo) || /^\s*\$\$\.$/.test(textUpTo)) {
    return { kind: "after_out" }
  }

  // After "."
  if (trimmed.endsWith(".") || /\.\w*$/.test(textUpTo)) {
    const { type, lastGroup, lastOrdinal } = inferTypeBeforeDot(
      source,
      line,
      col,
    )
    return { kind: "dot", currentType: type, lastGroup, lastOrdinal }
  }

  // After "$"
  if (/\$\w*$/.test(textUpTo)) {
    return { kind: "dollar" }
  }

  // Find the innermost open function/method call at cursor
  const allCallNames = [
    "filter",
    "search",
    ...Object.keys(METHOD_PARAM_VALUES),
    ...Object.keys(FUNCTION_SIGNATURES).filter((n) => n !== "search"),
  ]
  const innermost = findInnermostCall(textUpTo, allCallNames)

  if (innermost === "filter") {
    return analyzeTagFilterContext(textUpTo, "filter")
  }
  if (innermost === "search") {
    return analyzeSearchContext(textUpTo)
  }
  if (innermost && innermost in METHOD_PARAM_VALUES) {
    const paramName = detectParamName(textUpTo, innermost)
    return {
      kind: "inside_method_params",
      methodName: innermost,
      paramName: paramName ?? undefined,
    }
  }
  if (innermost && innermost in FUNCTION_SIGNATURES) {
    const paramName = detectParamName(textUpTo, innermost)
    return {
      kind: "inside_function_params",
      functionName: innermost,
      paramName: paramName ?? undefined,
    }
  }

  // Top-level (start of line or after whitespace)
  if (trimmed === "" || /^\s*$/.test(textUpTo)) {
    return { kind: "top_level" }
  }

  return { kind: "unknown" }
}

function analyzeSearchContext(textUpTo: string): AnalyzedContext {
  const innerText = extractCallInner(textUpTo, "search")
  if (innerText === null) {
    return { kind: "inside_search", subContext: "tag_key" }
  }

  const lastSegment = getLastSegment(innerText)
  const trimmedSeg = lastSegment.trimStart()

  // Check if cursor is after "key: " — tag value position
  const tagValueMatch = trimmedSeg.match(/^([\w:]+)\s*:\s*/)
  if (tagValueMatch) {
    return {
      kind: "inside_search",
      subContext: "tag_value",
      tagKey: tagValueMatch[1],
    }
  }

  // First argument position (no comma seen) — could be element type or tag key
  if (!innerText.includes(",")) {
    return { kind: "inside_search", subContext: "element_type" }
  }

  return { kind: "inside_search", subContext: "tag_key" }
}

function analyzeTagFilterContext(
  textUpTo: string,
  funcName: string,
): AnalyzedContext {
  const innerText = extractCallInner(textUpTo, funcName)
  if (innerText === null) {
    return { kind: "inside_filter", subContext: "tag_key" }
  }

  const lastSegment = getLastSegment(innerText)
  const trimmedSeg = lastSegment.trimStart()

  const tagValueMatch = trimmedSeg.match(/^([\w:]+)\s*:\s*/)
  if (tagValueMatch) {
    return {
      kind: "inside_filter",
      subContext: "tag_value",
      tagKey: tagValueMatch[1],
    }
  }

  return { kind: "inside_filter", subContext: "tag_key" }
}

function extractCallInner(text: string, funcName: string): string | null {
  const idx = text.lastIndexOf(`${funcName}(`)
  if (idx < 0) {
    return null
  }
  const start = idx + funcName.length + 1
  // Walk from start, collecting top-level content (skipping nested parens)
  let result = ""
  let depth = 0
  for (let i = start; i < text.length; i++) {
    if (text[i] === "(") {
      depth++
      result += text[i]
    } else if (text[i] === ")") {
      depth--
      if (depth < 0) {
        break
      }
      result += text[i]
    } else {
      result += text[i]
    }
  }
  return result
}

function getLastSegment(text: string): string {
  // Find last top-level comma (not inside nested parens)
  let depth = 0
  let lastComma = -1
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "(") {
      depth++
    } else if (text[i] === ")") {
      depth--
    } else if (text[i] === "," && depth === 0) {
      lastComma = i
    }
  }
  return lastComma >= 0 ? text.slice(lastComma + 1) : text
}

function detectParamName(textUpTo: string, funcName: string): string | null {
  const inner = extractCallInner(textUpTo, funcName)
  if (!inner) {
    return null
  }
  const lastSeg = getLastSegment(inner).trimStart()
  const match = lastSeg.match(/^(\w+)\s*:\s*/)
  return match ? match[1] : null
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: parser helper
function findInnermostCall(text: string, candidates: string[]): string | null {
  let best: string | null = null
  let bestPos = -1
  for (const name of candidates) {
    const idx = text.lastIndexOf(`${name}(`)
    if (idx < 0 || idx <= bestPos) {
      continue
    }
    // Word boundary check: ensure this isn't part of a longer identifier
    if (idx > 0 && /\w/.test(text[idx - 1] as string)) {
      continue
    }
    // Check if still open (paren depth > 0)
    const afterCall = text.slice(idx + name.length)
    let depth = 0
    for (const ch of afterCall) {
      if (ch === "(") {
        depth++
      }
      if (ch === ")") {
        depth--
      }
    }
    if (depth > 0) {
      best = name
      bestPos = idx
    }
  }
  return best
}

function inferTypeBeforeDot(
  source: string,
  line: number,
  col: number,
): { type: PqlType | null; lastGroup: MethodGroup; lastOrdinal: number } {
  try {
    const { ast } = parse(source)
    if (ast.length === 0) {
      return { type: null, lastGroup: "source", lastOrdinal: 0 }
    }
    return inferChainStateAtPosition(ast, line, col)
  } catch {
    return { type: null, lastGroup: "source", lastOrdinal: 0 }
  }
}

// ── Completion generators ────────────────────────────────────────────

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: completion helper
function getDotCompletions(
  _source: string,
  currentType: PqlType | null,
  lastGroup: MethodGroup,
  lastOrdinal: number,
): CompletionItem[] {
  // No chaining after terminal types
  if (currentType && isTerminal(currentType)) {
    return []
  }
  if (currentType && !isChainable(currentType)) {
    return []
  }

  const items: CompletionItem[] = []
  const noArgMethods = new Set([
    "centroid",
    "count",
    "ids",
    "tags",
    "skel",
    "elevation",
    "area",
    "length",
    "first",
    "last",
  ])

  for (const m of METHOD_CATALOG) {
    // Group ordering: don't suggest freely_orderable after late_chain or terminal
    if (m.group === "freely_orderable" && lastGroup === "late_chain") {
      continue
    }
    if (m.group === "freely_orderable" && lastGroup === "terminal") {
      continue
    }
    if (m.group === "late_chain" && lastGroup === "terminal") {
      continue
    }

    // Phase ordering within freely_orderable: don't suggest earlier phases after later ones
    if (
      m.group === "freely_orderable" &&
      lastGroup === "freely_orderable" &&
      lastOrdinal > 0
    ) {
      const mp = methodPhase(m.name)
      if (mp.ordinal < lastOrdinal && mp.ordinal > 0) {
        continue
      }
    }

    items.push({
      label: m.name,
      kind: "method",
      detail: `${m.signature} — ${m.phase}`,
      documentation: m.description,
      insertText: m.name + (noArgMethods.has(m.name) ? "()" : "("),
      sortText:
        (m.group === "terminal" ? "z" : m.group === "late_chain" ? "y" : "a") +
        m.name,
    })
  }

  return items
}

function getVariableCompletions(
  source: string,
  _beforeLine: number,
): CompletionItem[] {
  try {
    const { ast } = parse(source)
    const { scope } = typeCheck(ast)
    const items: CompletionItem[] = []

    for (const [name, info] of scope) {
      items.push({
        label: name,
        kind: "variable",
        detail: `:: ${info.type}`,
        documentation: `Defined at line ${info.line}`,
        insertText: name.slice(1), // without the $ since it's already typed
      })
    }

    return items
  } catch {
    return []
  }
}

function getTagCompletions(): CompletionItem[] {
  return OSM_TAG_DATABASE.map((tag) => ({
    label: tag.key,
    kind: "tag" as const,
    detail: tag.description,
    documentation:
      tag.values.length > 0
        ? `Values: ${tag.values
            .slice(0, 8)
            .map((v) => v.value)
            .join(", ")}${tag.values.length > 8 ? ", ..." : ""}`
        : "Free-form text value",
    insertText: `${tag.key}: `,
    sortText: String(tag.rank).padStart(3, "0"),
  }))
}

function getTagValueCompletions(tagKey: string): CompletionItem[] {
  const tagInfo = TAG_KEY_MAP.get(tagKey)
  const items: CompletionItem[] = []

  if (tagInfo) {
    for (const v of tagInfo.values) {
      items.push({
        label: `"${v.value}"`,
        kind: "value",
        detail: v.description ?? `${tagKey}=${v.value}`,
        insertText: `"${v.value}"`,
        sortText: `a${v.value}`,
      })
    }
  }

  // Always append filter operators
  items.push(...getFilterOperatorCompletions())

  return items
}

function getFilterOperatorCompletions(): CompletionItem[] {
  return [
    {
      label: "*",
      kind: "operator",
      detail: "Key exists (any value)",
      insertText: "*",
      sortText: "z1",
    },
    {
      label: "!*",
      kind: "operator",
      detail: "Key does not exist",
      insertText: "!*",
      sortText: "z2",
    },
    {
      label: '~"…"',
      kind: "operator",
      detail: "Regex match",
      insertText: '~"',
      sortText: "z3",
    },
    {
      label: '~i"…"',
      kind: "operator",
      detail: "Case-insensitive regex",
      insertText: '~i"',
      sortText: "z4",
    },
    {
      label: '!~"…"',
      kind: "operator",
      detail: "Negated regex",
      insertText: '!~"',
      sortText: "z5",
    },
    {
      label: '!"…"',
      kind: "operator",
      detail: "Not equal",
      insertText: '!"',
      sortText: "z6",
    },
  ]
}

function getElementTypeCompletions(): CompletionItem[] {
  return [
    {
      label: "node",
      kind: "keyword",
      detail: "OSM Node — points (shops, POIs, etc.)",
      insertText: "node, ",
      sortText: "!a",
    },
    {
      label: "way",
      kind: "keyword",
      detail: "OSM Way — lines and polygons (roads, buildings)",
      insertText: "way, ",
      sortText: "!b",
    },
    {
      label: "relation",
      kind: "keyword",
      detail: "OSM Relation — grouped elements (routes, boundaries)",
      insertText: "relation, ",
      sortText: "!c",
    },
    {
      label: "nwr",
      kind: "keyword",
      detail: "Any element type (node + way + relation)",
      insertText: "nwr, ",
      sortText: "!d",
    },
  ]
}

function getParamCompletions(functionName: string): CompletionItem[] {
  const sig = FUNCTION_SIGNATURES[functionName]
  if (!sig) {
    return []
  }

  return sig.params.map((p) => ({
    label: p.name,
    kind: "param" as const,
    detail: p.type,
    documentation: p.description,
    insertText: p.name.startsWith("...") ? "" : `${p.name}: `,
  }))
}

function getParamValueCompletions(
  functionName: string,
  paramName: string,
): CompletionItem[] {
  const sig = FUNCTION_SIGNATURES[functionName]
  if (!sig) {
    return []
  }
  const param = sig.params.find((p) => p.name === paramName)
  if (!param?.enumValues) {
    return getParamCompletions(functionName)
  }

  return param.enumValues.map((v) => ({
    label: v.value,
    kind: "value" as const,
    detail: v.description,
    insertText: v.value,
  }))
}

function getSortExpressionCompletions(): CompletionItem[] {
  return [
    {
      label: 't["',
      kind: "value",
      detail: "Tag value",
      insertText: 't["',
      sortText: "a1",
    },
    {
      label: "distance(",
      kind: "function",
      detail: "Distance from point",
      insertText: "distance(",
      sortText: "a2",
    },
    {
      label: "area()",
      kind: "function",
      detail: "Geometry area",
      insertText: "area()",
      sortText: "a3",
    },
    {
      label: "length()",
      kind: "function",
      detail: "Geometry length",
      insertText: "length()",
      sortText: "a4",
    },
    {
      label: "elevation()",
      kind: "function",
      detail: "Elevation at point",
      insertText: "elevation()",
      sortText: "a5",
    },
    {
      label: "number(",
      kind: "function",
      detail: "Numeric coercion",
      insertText: "number(",
      sortText: "a6",
    },
    {
      label: "id()",
      kind: "function",
      detail: "OSM ID",
      insertText: "id()",
      sortText: "a7",
    },
  ]
}

function getMethodParamCompletions(methodName: string): CompletionItem[] {
  if (methodName === "sort") {
    return [
      ...getSortExpressionCompletions(),
      {
        label: "by",
        kind: "param",
        detail: "expr",
        insertText: "by: ",
        sortText: "b1",
      },
      {
        label: "order",
        kind: "param",
        detail: ":asc | :desc",
        insertText: "order: ",
        sortText: "b2",
      },
    ]
  }

  const method = METHOD_CATALOG.find((m) => m.name === methodName)
  if (!method) {
    return []
  }

  // Extract params from signature string
  const paramMatch = method.signature.match(/\(([^)]*)\)/)
  if (!paramMatch) {
    return []
  }

  return paramMatch[1].split(",").map((p) => {
    const trimmed = p.trim()
    const parts = trimmed.split(":")
    const name = parts[0]?.trim().replace("?", "") ?? trimmed
    const type = parts[1]?.trim() ?? ""
    return {
      label: name,
      kind: "param" as const,
      detail: type,
      insertText: `${name}: `,
    }
  })
}

function getMethodParamValueCompletions(
  methodName: string,
  paramName: string,
): CompletionItem[] {
  if (methodName === "sort" && paramName === "by") {
    return getSortExpressionCompletions()
  }

  const paramValues = METHOD_PARAM_VALUES[methodName]
  if (!paramValues) {
    return getMethodParamCompletions(methodName)
  }
  const values = paramValues[paramName]
  if (!values) {
    return getMethodParamCompletions(methodName)
  }

  return values.map((v) => ({
    label: v.value,
    kind: "value" as const,
    detail: v.description,
    insertText: v.value,
  }))
}

function getTopLevelCompletions(): CompletionItem[] {
  const items: CompletionItem[] = [
    {
      label: "$",
      kind: "keyword",
      detail: "Variable assignment",
      insertText: "$",
      sortText: "y1",
    },
    {
      label: "$$",
      kind: "keyword",
      detail: "Output assignment",
      insertText: "$$ = ",
      sortText: "y2",
    },
    {
      label: "[",
      kind: "keyword",
      detail: "Settings block",
      insertText: "[",
      sortText: "z1",
    },
  ]

  // Add all global functions
  for (const [name, sig] of Object.entries(FUNCTION_SIGNATURES)) {
    items.push({
      label: name,
      kind: "function",
      detail: `${name}(...) → ${sig.returnType}`,
      documentation: sig.description,
      insertText: `${name}(`,
      sortText: `a${name}`,
    })
  }

  return items
}

function getOutputRefCompletions(source: string): CompletionItem[] {
  try {
    const { ast } = parse(source)
    typeCheck(ast)
    const items: CompletionItem[] = []

    for (const stmt of ast) {
      if (stmt.kind === "output" && stmt.name !== null) {
        items.push({
          label: stmt.name,
          kind: "variable",
          detail: ":: output variable",
          documentation: `Named output defined at line ${stmt.pos.line}`,
          insertText: stmt.name,
        })
      }
    }

    return items
  } catch {
    return []
  }
}

function getOutputCompletions(): CompletionItem[] {
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
  ]
}
