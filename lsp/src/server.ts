#!/usr/bin/env node

// PlazaQL Language Server — stdio JSON-RPC

import {
  createConnection,
  TextDocuments,
  ProposedFeatures,
  TextDocumentSyncKind,
  CompletionItemKind,
  DiagnosticSeverity,
  MarkupKind,
  SignatureHelpTriggerKind,
  SymbolKind,
  DocumentSymbol,
  CodeAction,
  CodeActionKind,
  Range,
  Position,
  SemanticTokensBuilder,
  SemanticTokensLegend,
} from "vscode-languageserver/node.js";

import { TextDocument } from "vscode-languageserver-textdocument";

import { getDiagnostics } from "./diagnostics.js";
import { getCompletions } from "./completions.js";
import { getHover } from "./hover.js";
import { getSignatureHelp } from "./signatures.js";
import { parse, parserReady } from "./parser.js";
import { typeCheck } from "./type-checker.js";
import { formatDocument } from "./formatter.js";
import { DIAGNOSTIC_DEBOUNCE_MS } from "./constants.js";

// ── Connection ───────────────────────────────────────────────────────

const connection = createConnection(ProposedFeatures.all);
const documents = new TextDocuments(TextDocument);

// ── Debounce state ───────────────────────────────────────────────────

const diagnosticTimers = new Map<string, ReturnType<typeof setTimeout>>();

// ── Semantic token types ─────────────────────────────────────────────

const tokenTypes = [
  "variable",
  "function",
  "method",
  "keyword",
  "string",
  "number",
  "operator",
  "type",
  "comment",
];
const tokenModifiers = ["declaration", "readonly"];

const legend: SemanticTokensLegend = {
  tokenTypes,
  tokenModifiers,
};

// ── Initialize ───────────────────────────────────────────────────────

connection.onInitialize(async () => {
  await parserReady;
  return {
    capabilities: {
      textDocumentSync: TextDocumentSyncKind.Incremental,
      completionProvider: {
        triggerCharacters: [".", "$", "(", ",", ":"],
        resolveProvider: false,
      },
      hoverProvider: true,
      signatureHelpProvider: {
        triggerCharacters: ["(", ","],
      },
      definitionProvider: true,
      referencesProvider: true,
      documentSymbolProvider: true,
      documentFormattingProvider: true,
      codeActionProvider: true,
      semanticTokensProvider: {
        legend,
        full: true,
      },
    },
  };
});

// ── Document events ──────────────────────────────────────────────────

documents.onDidChangeContent((change) => {
  const uri = change.document.uri;

  // Debounce diagnostics
  const existing = diagnosticTimers.get(uri);
  if (existing) clearTimeout(existing);

  diagnosticTimers.set(
    uri,
    setTimeout(() => {
      publishDiagnostics(change.document);
      diagnosticTimers.delete(uri);
    }, DIAGNOSTIC_DEBOUNCE_MS)
  );
});

documents.onDidClose((event) => {
  const timer = diagnosticTimers.get(event.document.uri);
  if (timer) clearTimeout(timer);
  diagnosticTimers.delete(event.document.uri);
  connection.sendDiagnostics({ uri: event.document.uri, diagnostics: [] });
});

function publishDiagnostics(doc: TextDocument): void {
  const source = doc.getText();
  const diags = getDiagnostics(source);

  connection.sendDiagnostics({
    uri: doc.uri,
    diagnostics: diags.map((d) => ({
      range: {
        start: { line: d.line - 1, character: d.col - 1 },
        end: { line: d.line - 1, character: d.col + 10 },
      },
      severity:
        d.severity === "error"
          ? DiagnosticSeverity.Error
          : DiagnosticSeverity.Warning,
      source: "plazaql",
      message: d.hint ? `${d.message}\nhint: ${d.hint}` : d.message,
    })),
  });
}

// ── Completions ──────────────────────────────────────────────────────

connection.onCompletion((params) => {
  const doc = documents.get(params.textDocument.uri);
  if (!doc) return [];

  const items = getCompletions(
    doc.getText(),
    params.position.line + 1,
    params.position.character + 1
  );

  return items.map((item) => ({
    label: item.label,
    kind: completionKindMap(item.kind),
    detail: item.detail,
    documentation: item.documentation,
    insertText: item.insertText,
    sortText: item.sortText,
  }));
});

function completionKindMap(kind: string): CompletionItemKind {
  switch (kind) {
    case "method":
      return CompletionItemKind.Method;
    case "variable":
      return CompletionItemKind.Variable;
    case "keyword":
      return CompletionItemKind.Keyword;
    case "tag":
      return CompletionItemKind.Property;
    case "function":
      return CompletionItemKind.Function;
    case "param":
      return CompletionItemKind.Field;
    case "value":
      return CompletionItemKind.Value;
    case "operator":
      return CompletionItemKind.Operator;
    default:
      return CompletionItemKind.Text;
  }
}

// ── Hover ────────────────────────────────────────────────────────────

connection.onHover((params) => {
  const doc = documents.get(params.textDocument.uri);
  if (!doc) return null;

  const result = getHover(
    doc.getText(),
    params.position.line + 1,
    params.position.character + 1
  );

  if (!result) return null;

  return {
    contents: {
      kind: MarkupKind.Markdown,
      value: "```plazaql\n" + result.contents + "\n```",
    },
  };
});

// ── Signature Help ───────────────────────────────────────────────────

connection.onSignatureHelp((params) => {
  const doc = documents.get(params.textDocument.uri);
  if (!doc) return null;

  const result = getSignatureHelp(
    doc.getText(),
    params.position.line + 1,
    params.position.character + 1
  );

  if (!result) return null;

  return {
    signatures: result.signatures.map((s) => ({
      label: s.label,
      documentation: s.documentation,
      parameters: s.parameters.map((p) => ({
        label: p.label,
        documentation: p.documentation,
      })),
    })),
    activeSignature: result.activeSignature,
    activeParameter: result.activeParameter,
  };
});

// ── Definition ───────────────────────────────────────────────────────

connection.onDefinition((params) => {
  const doc = documents.get(params.textDocument.uri);
  if (!doc) return null;

  const source = doc.getText();
  const line = params.position.line + 1;
  const col = params.position.character + 1;

  // Find the variable name at cursor
  const varName = getVarAtPosition(source, line, col);
  if (!varName) return null;

  // Find the assignment
  const { ast } = parse(source);
  for (const stmt of ast) {
    if (stmt.kind === "var_assign" && stmt.name === varName) {
      return {
        uri: doc.uri,
        range: {
          start: { line: stmt.pos.line - 1, character: stmt.pos.col - 1 },
          end: { line: stmt.pos.line - 1, character: stmt.pos.col - 1 + varName.length },
        },
      };
    }
  }

  return null;
});

// ── References ───────────────────────────────────────────────────────

connection.onReferences((params) => {
  const doc = documents.get(params.textDocument.uri);
  if (!doc) return null;

  const source = doc.getText();
  const line = params.position.line + 1;
  const col = params.position.character + 1;

  const varName = getVarAtPosition(source, line, col);
  if (!varName) return null;

  // Find all occurrences of the variable
  const locations: Array<{ uri: string; range: { start: Position; end: Position } }> = [];
  const lines = source.split("\n");

  for (let i = 0; i < lines.length; i++) {
    let idx = 0;
    const lineText = lines[i]!;
    while ((idx = lineText.indexOf(varName, idx)) >= 0) {
      locations.push({
        uri: doc.uri,
        range: {
          start: { line: i, character: idx },
          end: { line: i, character: idx + varName.length },
        },
      });
      idx += varName.length;
    }
  }

  return locations;
});

// ── Document Symbols ─────────────────────────────────────────────────

connection.onDocumentSymbol((params) => {
  const doc = documents.get(params.textDocument.uri);
  if (!doc) return null;

  const { ast } = parse(doc.getText());
  const { scope } = typeCheck(ast);
  const symbols: DocumentSymbol[] = [];

  for (const stmt of ast) {
    if (stmt.kind === "var_assign") {
      const info = scope.get(stmt.name);
      symbols.push(
        DocumentSymbol.create(
          stmt.name,
          info ? `:: ${info.type}` : undefined,
          SymbolKind.Variable,
          Range.create(stmt.pos.line - 1, stmt.pos.col - 1, stmt.pos.line - 1, stmt.pos.col + stmt.name.length),
          Range.create(stmt.pos.line - 1, stmt.pos.col - 1, stmt.pos.line - 1, stmt.pos.col + stmt.name.length)
        )
      );
    } else if (stmt.kind === "bare_output") {
      symbols.push(
        DocumentSymbol.create(
          "(output)",
          undefined,
          SymbolKind.Field,
          Range.create(stmt.pos.line - 1, stmt.pos.col - 1, stmt.pos.line - 1, stmt.pos.col + 6),
          Range.create(stmt.pos.line - 1, stmt.pos.col - 1, stmt.pos.line - 1, stmt.pos.col + 6)
        )
      );
    } else if (stmt.kind === "output") {
      const label = stmt.name ? `$$.${stmt.name}` : "$$";
      symbols.push(
        DocumentSymbol.create(
          label,
          undefined,
          SymbolKind.Field,
          Range.create(stmt.pos.line - 1, stmt.pos.col - 1, stmt.pos.line - 1, stmt.pos.col + label.length),
          Range.create(stmt.pos.line - 1, stmt.pos.col - 1, stmt.pos.line - 1, stmt.pos.col + label.length)
        )
      );
    }
  }

  return symbols;
});

// ── Formatting ───────────────────────────────────────────────────────

connection.onDocumentFormatting((params) => {
  const doc = documents.get(params.textDocument.uri);
  if (!doc) return null;

  const source = doc.getText();
  const formatted = formatDocument(source);
  if (!formatted || formatted === source) return null;

  return [
    {
      range: {
        start: { line: 0, character: 0 },
        end: doc.positionAt(source.length),
      },
      newText: formatted,
    },
  ];
});

// ── Code Actions ─────────────────────────────────────────────────────

connection.onCodeAction((params) => {
  const doc = documents.get(params.textDocument.uri);
  if (!doc) return [];

  const actions: CodeAction[] = [];

  // Look for phase ordering errors and offer to reorder
  for (const diag of params.context.diagnostics) {
    if (diag.message.includes("cannot follow")) {
      actions.push({
        title: "Reorder method chain",
        kind: CodeActionKind.QuickFix,
        diagnostics: [diag],
        // A real implementation would compute the edit; for now just offer the action
        isPreferred: true,
      });
    }
  }

  return actions;
});

// ── Semantic Tokens ──────────────────────────────────────────────────

connection.languages.semanticTokens.on((params) => {
  const doc = documents.get(params.textDocument.uri);
  if (!doc) return { data: [] };

  const builder = new SemanticTokensBuilder();
  const source = doc.getText();
  const { ast } = parse(source);

  for (const stmt of ast) {
    if (stmt.kind === "var_assign") {
      // Highlight variable name
      builder.push(
        stmt.pos.line - 1,
        stmt.pos.col - 1,
        stmt.name.length,
        0, // variable
        1  // declaration
      );
    } else if (stmt.kind === "output") {
      builder.push(
        stmt.pos.line - 1,
        stmt.pos.col - 1,
        stmt.name ? `$$.${stmt.name}`.length : 2,
        3, // keyword
        0
      );
    } else if (stmt.kind === "bare_output") {
      // No keyword token — bare expressions have no $$ prefix
    } else if (stmt.kind === "settings") {
      builder.push(
        stmt.pos.line - 1,
        stmt.pos.col - 1,
        1,
        3, // keyword
        0
      );
    }
  }

  return builder.build();
});

// ── Helper functions ─────────────────────────────────────────────────

function getVarAtPosition(
  source: string,
  line: number,
  col: number
): string | null {
  const lines = source.split("\n");
  const currentLine = lines[line - 1];
  if (!currentLine) return null;

  const idx = col - 1;

  // Look for $ variable
  let start = idx;
  while (start > 0 && isIdentChar(currentLine[start - 1]!)) start--;
  if (start > 0 && currentLine[start - 1] === "$") start--;

  if (currentLine[start] !== "$") return null;

  let end = start + 1;
  while (end < currentLine.length && isIdentChar(currentLine[end]!)) end++;

  return currentLine.slice(start, end);
}

function isIdentChar(ch: string): boolean {
  return (
    (ch >= "a" && ch <= "z") ||
    (ch >= "A" && ch <= "Z") ||
    (ch >= "0" && ch <= "9") ||
    ch === "_"
  );
}

// ── Start ────────────────────────────────────────────────────────────

documents.listen(connection);
connection.listen();
