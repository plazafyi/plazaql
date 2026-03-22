// PlazaQL recursive descent parser — ported from Plaza.PlazaQL.Parser

import type {
  Pos,
  Expr,
  Statement,
  TagFilter,
  ElementType,
  Arg,
  MethodNode,
  SearchNode,
  ComputationName,
  NumberNode,
  StringNode,
  BoolNode,
  AtomNode,
  IdentifierNode,
  VarRefNode,
  PointNode,
  BboxNode,
  GeometryNode,
  ComputationNode,
  AreaNode,
  ChainNode,
  ArrowChainNode,
  UnionNode,
  DifferenceNode,
  ListNode,
  SettingsNode,
  VarAssignNode,
  OutputNode,
} from "./types.js";

// ── Diagnostic ───────────────────────────────────────────────────────

export interface ParseError {
  line: number;
  col: number;
  message: string;
}

export interface ParseResult {
  ast: Statement[];
  errors: ParseError[];
}

// ── Known identifiers ────────────────────────────────────────────────

const COMPUTATION_NAMES = new Set([
  "route",
  "isochrone",
  "geocode",
  "reverse_geocode",
  "autocomplete",
  "text_search",
  "matrix",
  "map_match",
  "optimize",
  "ev_route",
  "elevation",
  "elevation_profile",
  "nearest",
]);

const ELEMENT_TYPES = new Set(["node", "way", "relation", "nwr", "nw", "nr", "wr"]);

const _METHOD_ATOMS = new Set([
  "around",
  "bbox",
  "buffer",
  "centroid",
  "contains",
  "count",
  "crosses",
  "distance",
  "elevation",
  "expand",
  "fields",
  "filter",
  "h3",
  "ids",
  "include",
  "intersects",
  "limit",
  "near",
  "not_contains",
  "not_intersects",
  "not_within",
  "offset",
  "precision",
  "simplify",
  "skel",
  "sort",
  "tags",
  "touches",
  "within",
  "area",
  "length",
]);

// ── Parser class ─────────────────────────────────────────────────────

class Parser {
  private src: string;
  private pos: number;
  private line: number;
  private col: number;
  private errors: ParseError[];

  constructor(src: string) {
    this.src = src;
    this.pos = 0;
    this.line = 1;
    this.col = 1;
    this.errors = [];
  }

  // ── Public ───────────────────────────────────────────────────────

  parse(): ParseResult {
    const stmts: Statement[] = [];
    this.skipWs();
    while (!this.eof()) {
      const stmt = this.parseStatement();
      if (stmt) {
        stmts.push(stmt);
      } else {
        // Error recovery: skip to next semicolon or recognizable construct
        this.recoverToNextStatement();
      }
      this.skipWs();
    }
    return { ast: stmts, errors: this.errors };
  }

  // ── Position helpers ─────────────────────────────────────────────

  private markPos(): Pos {
    return { line: this.line, col: this.col };
  }

  private peek(offset = 0): string {
    return this.src[this.pos + offset] ?? "";
  }

  private peekStr(len: number): string {
    return this.src.slice(this.pos, this.pos + len);
  }

  private eof(): boolean {
    return this.pos >= this.src.length;
  }

  private advance(): string {
    const ch = this.src[this.pos] ?? "";
    this.pos++;
    if (ch === "\n") {
      this.line++;
      this.col = 1;
    } else {
      this.col++;
    }
    return ch;
  }

  private expect(ch: string): boolean {
    if (this.peek() === ch) {
      this.advance();
      return true;
    }
    this.addError(`expected '${ch}'`);
    return false;
  }

  private addError(message: string, pos?: Pos): void {
    const p = pos ?? this.markPos();
    this.errors.push({ line: p.line, col: p.col, message });
  }

  // ── Whitespace & comments ────────────────────────────────────────

  private skipWs(): void {
    while (!this.eof()) {
      const ch = this.peek();
      if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r") {
        this.advance();
      } else if (ch === "/" && this.peek(1) === "/") {
        // Line comment
        while (!this.eof() && this.peek() !== "\n") this.advance();
      } else if (ch === "/" && this.peek(1) === "*") {
        // Block comment
        this.advance();
        this.advance();
        while (!this.eof()) {
          if (this.peek() === "*" && this.peek(1) === "/") {
            this.advance();
            this.advance();
            break;
          }
          this.advance();
        }
      } else {
        break;
      }
    }
  }

  // ── Error recovery ───────────────────────────────────────────────

  private recoverToNextStatement(): void {
    const pos = this.markPos();
    // Collect some context for error message
    const start = this.pos;
    while (!this.eof() && this.peek() !== ";") {
      this.advance();
    }
    if (this.peek() === ";") this.advance();
    const snippet = this.src.slice(start, Math.min(start + 30, this.src.length));
    if (snippet.trim()) {
      this.addError(`unexpected input near: "${snippet.trim()}"`, pos);
    }
  }

  // ── Statement parsers ────────────────────────────────────────────

  private parseStatement(): Statement | null {
    this.skipWs();
    if (this.eof()) return null;

    // Settings block: [...]
    if (this.peek() === "[") {
      return this.parseSettings();
    }

    // Output assignment: $$ = expr; or $$.name = expr;
    if (this.peek() === "$" && this.peek(1) === "$") {
      return this.parseOutput();
    }

    // Variable assignment: $name = expr;
    if (this.peek() === "$") {
      return this.parseVarAssign();
    }

    return null;
  }

  private peekWord(): string {
    let i = this.pos;
    while (i < this.src.length && isIdentChar(this.src[i]!)) i++;
    return this.src.slice(this.pos, i);
  }

  // ── Settings ─────────────────────────────────────────────────────

  private parseSettings(): SettingsNode | null {
    const pos = this.markPos();
    this.advance(); // skip [
    this.skipWs();

    const pairs: Array<{ key: string; value: string | number | boolean }> = [];
    while (!this.eof() && this.peek() !== "]") {
      const key = this.parseIdent();
      if (!key) break;
      this.skipWs();
      if (!this.expect(":")) break;
      this.skipWs();
      const val = this.parseSettingValue();
      if (val === null) break;
      pairs.push({ key, value: val });
      this.skipWs();
      if (this.peek() === ",") {
        this.advance();
        this.skipWs();
      }
    }
    if (this.peek() === "]") this.advance();
    return { kind: "settings", pairs, pos };
  }

  private parseSettingValue(): string | number | boolean | null {
    if (this.peek() === '"') return this.parseStringValue();
    if (this.peekStr(4) === "true" && !isIdentChar(this.src[this.pos + 4] ?? "")) {
      this.pos += 4;
      this.col += 4;
      return true;
    }
    if (this.peekStr(5) === "false" && !isIdentChar(this.src[this.pos + 5] ?? "")) {
      this.pos += 5;
      this.col += 5;
      return false;
    }
    return this.parseNumberValue();
  }

  // ── Variable assignment ──────────────────────────────────────────

  private parseVarAssign(): VarAssignNode | null {
    const pos = this.markPos();
    this.advance(); // skip $
    const name = this.parseIdent();
    if (!name) {
      this.addError("expected variable name after '$'", pos);
      return null;
    }
    this.skipWs();
    if (!this.expect("=")) return null;
    this.skipWs();
    const expr = this.parseExpr();
    if (!expr) {
      this.addError("expected expression after '='", pos);
      return null;
    }
    this.skipWs();
    this.expect(";");
    return { kind: "var_assign", name: `$${name}`, expr, pos };
  }

  // ── Output assignment ────────────────────────────────────────────

  private parseOutput(): OutputNode | null {
    const pos = this.markPos();
    this.advance(); // skip first $
    this.advance(); // skip second $
    let name: string | null = null;
    if (this.peek() === ".") {
      this.advance();
      name = this.parseIdent();
    }
    this.skipWs();
    if (!this.expect("=")) return null;
    this.skipWs();
    const expr = this.parseExpr();
    if (!expr) {
      this.addError("expected expression after '='", pos);
      return null;
    }
    this.skipWs();
    this.expect(";");
    return { kind: "output", name, expr, pos };
  }

  // ── Expression parsing (precedence climbing) ─────────────────────

  parseExpr(): Expr | null {
    return this.parseSetExpr();
  }

  private parseSetExpr(): Expr | null {
    let left = this.parseArrowOrChain();
    if (!left) return null;

    while (!this.eof()) {
      this.skipWs();
      if (this.peek() === "+") {
        const pos = left.pos;
        this.advance();
        this.skipWs();
        const right = this.parseArrowOrChain();
        if (!right) {
          this.addError("expected expression after '+'");
          break;
        }
        left = { kind: "union", left, right, pos } as UnionNode;
      } else if (this.peek() === "-") {
        // Disambiguate minus: only treat as set op if followed by ident start, $, or (
        const saved = this.saveState();
        this.advance();
        this.skipWs();
        const next = this.peek();
        if (isIdentStart(next) || next === "$" || next === "(") {
          const pos = left.pos;
          const right = this.parseArrowOrChain();
          if (!right) {
            this.addError("expected expression after '-'");
            break;
          }
          left = { kind: "difference", left, right, pos } as DifferenceNode;
        } else {
          this.restoreState(saved);
          break;
        }
      } else {
        break;
      }
    }
    return left;
  }

  private parseArrowOrChain(): Expr | null {
    const first = this.parseChainExpr();
    if (!first) return null;

    const items: Expr[] = [first];
    while (!this.eof()) {
      this.skipWs();
      if (this.peekStr(2) === "->") {
        this.advance();
        this.advance();
        this.skipWs();
        const next = this.parseChainExpr();
        if (!next) {
          this.addError("expected expression after '->'");
          break;
        }
        items.push(next);
      } else {
        break;
      }
    }

    if (items.length === 1) return items[0]!;
    return { kind: "arrow_chain", items, pos: first.pos } as ArrowChainNode;
  }

  private parseChainExpr(): Expr | null {
    let expr = this.parsePrimary();
    if (!expr) return null;

    // Method chain
    while (!this.eof()) {
      this.skipWs();
      if (this.peek() !== ".") break;
      // Check if it's really a method call: . followed by ident
      const saved = this.saveState();
      this.advance(); // skip .
      this.skipWs();
      const methodPos = this.markPos();
      const methodName = this.parseIdent();
      if (!methodName) {
        this.restoreState(saved);
        break;
      }

      // Is it a method with args?
      this.skipWs();
      let method: MethodNode;
      if (this.peek() === "(") {
        this.advance(); // skip (
        this.skipWs();
        if (methodName === "filter") {
          // filter() takes tag filters, not regular args
          const filters = this.parseTagFilterList();
          this.skipWs();
          if (this.peek() === ")") this.advance();
          method = { kind: "method", name: methodName, args: filters, pos: methodPos };
        } else {
          const args = this.parseArgList();
          this.skipWs();
          if (this.peek() === ")") this.advance();
          method = { kind: "method", name: methodName, args, pos: methodPos };
        }
      } else {
        // No-arg method
        method = { kind: "method", name: methodName, args: [], pos: methodPos };
      }

      // Special handling for search: attach methods directly
      if (expr.kind === "search") {
        (expr as SearchNode).methods.push(method);
      } else {
        expr = { kind: "chain", receiver: expr, method, pos: expr.pos } as ChainNode;
      }
    }

    return expr;
  }

  // ── Primary expression ───────────────────────────────────────────

  private parsePrimary(): Expr | null {
    this.skipWs();
    if (this.eof()) return null;

    const ch = this.peek();

    // Parenthesized expression
    if (ch === "(") {
      this.advance();
      this.skipWs();
      const expr = this.parseExpr();
      this.skipWs();
      if (this.peek() === ")") this.advance();
      return expr;
    }

    // Variable reference
    if (ch === "$") {
      return this.parseVarRef();
    }

    // String literal
    if (ch === '"') {
      return this.parseString();
    }

    // Number literal (including negative)
    if (isDigit(ch) || (ch === "-" && isDigit(this.peek(1)))) {
      return this.parseNumber();
    }

    // Boolean
    if (this.peekStr(4) === "true" && !isIdentChar(this.src[this.pos + 4] ?? "")) {
      const pos = this.markPos();
      this.pos += 4;
      this.col += 4;
      return { kind: "bool", value: true, pos } as BoolNode;
    }
    if (this.peekStr(5) === "false" && !isIdentChar(this.src[this.pos + 5] ?? "")) {
      const pos = this.markPos();
      this.pos += 5;
      this.col += 5;
      return { kind: "bool", value: false, pos } as BoolNode;
    }

    // Atom literal
    if (ch === ":" && isIdentStart(this.peek(1))) {
      return this.parseAtom();
    }

    // List literal
    if (ch === "[") {
      return this.parseList();
    }

    // Keyword identifier
    if (isIdentStart(ch)) {
      return this.parseIdentOrCall();
    }

    return null;
  }

  // ── Var ref ──────────────────────────────────────────────────────

  private parseVarRef(): VarRefNode {
    const pos = this.markPos();
    this.advance(); // skip $
    const name = this.parseIdent() ?? "";
    return { kind: "var_ref", name: `$${name}`, pos };
  }

  // ── Number ───────────────────────────────────────────────────────

  private parseNumber(): NumberNode {
    const pos = this.markPos();
    let str = "";
    if (this.peek() === "-") str += this.advance();
    while (!this.eof() && isDigit(this.peek())) str += this.advance();
    if (this.peek() === "." && isDigit(this.peek(1))) {
      str += this.advance(); // .
      while (!this.eof() && isDigit(this.peek())) str += this.advance();
    }
    const value = str.includes(".") ? parseFloat(str) : parseInt(str, 10);
    return { kind: "number", value, pos };
  }

  private parseNumberValue(): number | null {
    const node = this.parseNumber();
    return node.value;
  }

  // ── String ───────────────────────────────────────────────────────

  private parseString(): StringNode {
    const pos = this.markPos();
    const value = this.parseStringValue() ?? "";
    return { kind: "string", value, pos };
  }

  private parseStringValue(): string | null {
    if (this.peek() !== '"') return null;
    this.advance(); // skip opening "
    let value = "";
    while (!this.eof() && this.peek() !== '"') {
      if (this.peek() === "\\") {
        this.advance();
        const esc = this.advance();
        switch (esc) {
          case "n":
            value += "\n";
            break;
          case "t":
            value += "\t";
            break;
          case '"':
            value += '"';
            break;
          case "\\":
            value += "\\";
            break;
          default:
            value += esc;
        }
      } else {
        value += this.advance();
      }
    }
    if (this.peek() === '"') this.advance(); // skip closing "
    return value;
  }

  // ── Bool ─────────────────────────────────────────────────────────
  // (handled inline in parsePrimary)

  // ── Atom ─────────────────────────────────────────────────────────

  private parseAtom(): AtomNode {
    const pos = this.markPos();
    this.advance(); // skip :
    const name = this.parseIdent() ?? "";
    return { kind: "atom", value: name, pos };
  }

  // ── List ─────────────────────────────────────────────────────────

  private parseList(): ListNode {
    const pos = this.markPos();
    this.advance(); // skip [
    this.skipWs();
    const items: Expr[] = [];
    while (!this.eof() && this.peek() !== "]") {
      const item = this.parseExpr();
      if (!item) break;
      items.push(item);
      this.skipWs();
      if (this.peek() === ",") {
        this.advance();
        this.skipWs();
      }
    }
    if (this.peek() === "]") this.advance();
    return { kind: "list", items, pos };
  }

  // ── Identifier / function call ───────────────────────────────────

  private parseIdentOrCall(): Expr | null {
    const pos = this.markPos();
    const name = this.parseIdent();
    if (!name) return null;

    // Check if it's search()
    if (name === "search") {
      return this.parseSearch(pos);
    }

    // Check if it's area()
    if (name === "area") {
      this.skipWs();
      if (this.peek() === "(") {
        return this.parseArea(pos);
      }
      // bare 'area' identifier
      return { kind: "identifier", name, pos } as IdentifierNode;
    }

    // Check if it's a computation function
    if (COMPUTATION_NAMES.has(name)) {
      return this.parseComputation(name as ComputationName, pos);
    }

    // Geometry constructors
    if (name === "point") return this.parsePoint(pos);
    if (name === "bbox") return this.parseBbox(pos);
    if (name === "linestring" || name === "polygon" || name === "circle") {
      return this.parseGeometry(name as "linestring" | "polygon" | "circle", pos);
    }

    // Check if it's a function call we don't recognize (don't eat the parens)
    // Just return as a bare identifier
    return { kind: "identifier", name, pos } as IdentifierNode;
  }

  // ── Search ───────────────────────────────────────────────────────

  private parseSearch(pos: Pos): SearchNode {
    this.skipWs();
    if (this.peek() !== "(") {
      return { kind: "search", elementType: null, filters: [], methods: [], pos };
    }
    this.advance(); // skip (
    this.skipWs();

    let elementType: ElementType | null = null;
    const filters: TagFilter[] = [];

    if (this.peek() !== ")") {
      // Try to parse element type
      const word = this.peekWord();
      if (ELEMENT_TYPES.has(word)) {
        // Check it's an element type, not a tag key followed by :
        const afterWord = this.pos + word.length;
        let tempIdx = afterWord;
        while (tempIdx < this.src.length && (this.src[tempIdx] === " " || this.src[tempIdx] === "\t")) tempIdx++;
        if (this.src[tempIdx] === ":") {
          // It's a tag filter key, not element type
          this.parseTagFiltersInto(filters);
        } else {
          elementType = word as ElementType;
          this.consumeWord(word);
          this.skipWs();
          if (this.peek() === ",") {
            this.advance();
            this.skipWs();
            this.parseTagFiltersInto(filters);
          }
        }
      } else {
        this.parseTagFiltersInto(filters);
      }
    }

    this.skipWs();
    if (this.peek() === ")") this.advance();
    return { kind: "search", elementType, filters, methods: [], pos };
  }

  // ── Area ─────────────────────────────────────────────────────────

  private parseArea(pos: Pos): AreaNode {
    this.advance(); // skip (
    this.skipWs();
    const filters: TagFilter[] = [];
    if (this.peek() !== ")") {
      this.parseTagFiltersInto(filters);
    }
    this.skipWs();
    if (this.peek() === ")") this.advance();
    return { kind: "area", filters, pos };
  }

  // ── Computation ──────────────────────────────────────────────────

  private parseComputation(name: ComputationName, pos: Pos): ComputationNode {
    this.skipWs();
    let args: Arg[] = [];
    if (this.peek() === "(") {
      this.advance();
      this.skipWs();
      args = this.parseArgList();
      this.skipWs();
      if (this.peek() === ")") this.advance();
    }
    return { kind: "computation", name, args, pos };
  }

  // ── Point ────────────────────────────────────────────────────────

  private parsePoint(pos: Pos): PointNode {
    this.skipWs();
    if (this.peek() !== "(") {
      return { kind: "point", lat: null, lng: null, args: [], pos };
    }
    this.advance();
    this.skipWs();
    const args = this.parseArgList();
    this.skipWs();
    if (this.peek() === ")") this.advance();

    // Try to extract lat/lng
    const { lat, lng } = extractLatLng(args);
    return { kind: "point", lat, lng, args, pos };
  }

  // ── Bbox ─────────────────────────────────────────────────────────

  private parseBbox(pos: Pos): BboxNode {
    this.skipWs();
    if (this.peek() !== "(") {
      return { kind: "bbox", s: null, w: null, n: null, e: null, args: [], pos };
    }
    this.advance();
    this.skipWs();
    const args = this.parseArgList();
    this.skipWs();
    if (this.peek() === ")") this.advance();

    const coords = extractBboxCoords(args);
    return { kind: "bbox", ...coords, args, pos };
  }

  // ── Geometry (linestring, polygon, circle) ───────────────────────

  private parseGeometry(
    name: "linestring" | "polygon" | "circle",
    pos: Pos
  ): GeometryNode {
    this.skipWs();
    const items: Expr[] = [];
    if (this.peek() === "(") {
      this.advance();
      this.skipWs();
      while (!this.eof() && this.peek() !== ")") {
        const item = this.parseExpr();
        if (!item) break;
        items.push(item);
        this.skipWs();
        if (this.peek() === ",") {
          this.advance();
          this.skipWs();
        }
      }
      if (this.peek() === ")") this.advance();
    }
    return { kind: name, items, pos };
  }

  // ── Tag filters ──────────────────────────────────────────────────

  private parseTagFilterList(): TagFilter[] {
    const filters: TagFilter[] = [];
    this.parseTagFiltersInto(filters);
    return filters;
  }

  private parseTagFiltersInto(filters: TagFilter[]): void {
    while (!this.eof()) {
      const f = this.parseTagFilter();
      if (!f) break;
      filters.push(f);
      this.skipWs();
      if (this.peek() === ",") {
        this.advance();
        this.skipWs();
      } else {
        break;
      }
    }
  }

  private parseTagFilter(): TagFilter | null {
    const saved = this.saveState();
    const key = this.parseIdent();
    if (!key) return null;
    this.skipWs();
    if (this.peek() !== ":") {
      this.restoreState(saved);
      return null;
    }
    this.advance(); // skip :
    this.skipWs();

    // !* (not_exists)
    if (this.peek() === "!" && this.peek(1) === "*") {
      this.advance();
      this.advance();
      return { op: "not_exists", key };
    }
    // * (exists)
    if (this.peek() === "*") {
      this.advance();
      return { op: "exists", key };
    }
    // !~ "pattern" (not_regex)
    if (this.peek() === "!" && this.peek(1) === "~") {
      this.advance();
      this.advance();
      this.skipWs();
      const val = this.parseStringValue() ?? "";
      return { op: "not_regex", key, value: val };
    }
    // ~i"pattern" (regex case insensitive)
    if (this.peek() === "~" && this.peek(1) === "i") {
      this.advance();
      this.advance();
      const val = this.parseStringValue() ?? "";
      return { op: "regex_i", key, value: val };
    }
    // ~"pattern" (regex)
    if (this.peek() === "~") {
      this.advance();
      this.skipWs();
      const val = this.parseStringValue() ?? "";
      return { op: "regex", key, value: val };
    }
    // !"value" (neq)
    if (this.peek() === "!" && this.peek(1) === '"') {
      this.advance();
      this.skipWs();
      const val = this.parseStringValue() ?? "";
      return { op: "neq", key, value: val };
    }
    // "value" (eq)
    if (this.peek() === '"') {
      const val = this.parseStringValue() ?? "";
      return { op: "eq", key, value: val };
    }

    // Unrecognized value
    this.restoreState(saved);
    return null;
  }

  // ── Argument list ────────────────────────────────────────────────

  private parseArgList(): Arg[] {
    const args: Arg[] = [];
    while (!this.eof() && this.peek() !== ")") {
      const arg = this.parseArg();
      if (!arg) break;
      args.push(arg);
      this.skipWs();
      if (this.peek() === ",") {
        this.advance();
        this.skipWs();
      } else {
        break;
      }
    }
    return args;
  }

  private parseArg(): Arg | null {
    this.skipWs();
    // Try keyword arg: ident ":" expr
    const saved = this.saveState();
    if (isIdentStart(this.peek())) {
      const name = this.parseIdent();
      if (name) {
        this.skipWs();
        if (this.peek() === ":") {
          this.advance();
          this.skipWs();
          const value = this.parseExpr();
          if (value) {
            return { type: "kwarg", name, value };
          }
        }
      }
    }
    this.restoreState(saved);

    // Positional arg
    const value = this.parseExpr();
    if (!value) return null;
    return { type: "posarg", value };
  }

  // ── Identifier ───────────────────────────────────────────────────

  private parseIdent(): string | null {
    if (!isIdentStart(this.peek())) return null;
    let name = this.advance();
    while (!this.eof() && isIdentChar(this.peek())) {
      name += this.advance();
    }
    return name;
  }

  private consumeWord(word: string): void {
    for (let i = 0; i < word.length; i++) this.advance();
  }

  // ── State save/restore for backtracking ──────────────────────────

  private saveState(): { pos: number; line: number; col: number; errLen: number } {
    return { pos: this.pos, line: this.line, col: this.col, errLen: this.errors.length };
  }

  private restoreState(state: { pos: number; line: number; col: number; errLen: number }): void {
    this.pos = state.pos;
    this.line = state.line;
    this.col = state.col;
    this.errors.length = state.errLen;
  }
}

// ── Character helpers ────────────────────────────────────────────────

function isDigit(ch: string): boolean {
  return ch >= "0" && ch <= "9";
}

function isIdentStart(ch: string): boolean {
  return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch === "_";
}

function isIdentChar(ch: string): boolean {
  return isIdentStart(ch) || isDigit(ch);
}

// ── Arg extraction helpers ───────────────────────────────────────────

function extractLatLng(args: Arg[]): { lat: number | null; lng: number | null } {
  if (args.length === 2) {
    // Positional: point(lat, lng)
    if (args[0]!.type === "posarg" && args[1]!.type === "posarg") {
      const a = args[0]!.value;
      const b = args[1]!.value;
      if (a.kind === "number" && b.kind === "number") {
        return { lat: a.value, lng: b.value };
      }
    }
    // Keyword: point(lat: n, lng: n)
    if (args[0]!.type === "kwarg" && args[1]!.type === "kwarg") {
      const a = args[0]!;
      const b = args[1]!;
      let lat: number | null = null;
      let lng: number | null = null;
      if (a.name === "lat" && a.value.kind === "number") lat = a.value.value;
      if (a.name === "lng" && a.value.kind === "number") lng = a.value.value;
      if (b.name === "lat" && b.value.kind === "number") lat = b.value.value;
      if (b.name === "lng" && b.value.kind === "number") lng = b.value.value;
      return { lat, lng };
    }
  }
  return { lat: null, lng: null };
}

function extractBboxCoords(args: Arg[]): {
  s: number | null;
  w: number | null;
  n: number | null;
  e: number | null;
} {
  if (
    args.length === 4 &&
    args.every((a) => a.type === "posarg" && a.value.kind === "number")
  ) {
    return {
      s: (args[0]!.value as NumberNode).value,
      w: (args[1]!.value as NumberNode).value,
      n: (args[2]!.value as NumberNode).value,
      e: (args[3]!.value as NumberNode).value,
    };
  }
  return { s: null, w: null, n: null, e: null };
}

// ── Public API ───────────────────────────────────────────────────────

export function parse(source: string): ParseResult {
  const parser = new Parser(source);
  return parser.parse();
}
