// PlazaQL signature help provider

import { FUNCTION_SIGNATURES, METHOD_CATALOG } from "./types.js";
import type { FunctionSignature } from "./types.js";

export interface SignatureHelp {
  signatures: SignatureInfo[];
  activeSignature: number;
  activeParameter: number;
}

export interface SignatureInfo {
  label: string;
  documentation?: string;
  parameters: ParameterInfo[];
}

export interface ParameterInfo {
  label: string;
  documentation?: string;
}

export function getSignatureHelp(
  source: string,
  line: number,
  col: number
): SignatureHelp | null {
  const lines = source.split("\n");
  const currentLine = lines[line - 1];
  if (!currentLine) return null;

  const textBefore = currentLine.slice(0, col - 1);

  // Find the innermost open function/method call
  const callInfo = findOpenCall(textBefore);
  if (!callInfo) return null;

  const { name, commaCount, isDot } = callInfo;

  // Look up function signature
  let sig: FunctionSignature | undefined;

  if (isDot) {
    // Method call — find in METHOD_CATALOG
    const method = METHOD_CATALOG.find((m) => m.name === name);
    if (method) {
      // Build a pseudo-signature from the catalog
      sig = {
        name: "." + method.name,
        params: parseMethodParams(method.signature),
        returnType: "same type",
        description: method.description,
      };
    }
  } else {
    sig = FUNCTION_SIGNATURES[name];
  }

  if (!sig) return null;

  const paramLabels = sig.params.map(
    (p) => `${p.name}${p.optional ? "?" : ""}: ${p.type}`
  );
  const sigLabel = `${sig.name}(${paramLabels.join(", ")})`;

  const parameters: ParameterInfo[] = sig.params.map((p) => ({
    label: `${p.name}${p.optional ? "?" : ""}: ${p.type}`,
    documentation: p.description,
  }));

  return {
    signatures: [
      {
        label: sigLabel,
        documentation: sig.description,
        parameters,
      },
    ],
    activeSignature: 0,
    activeParameter: Math.min(commaCount, parameters.length - 1),
  };
}

function findOpenCall(text: string): {
  name: string;
  commaCount: number;
  isDot: boolean;
} | null {
  // Walk backwards to find the open paren
  let depth = 0;
  let commaCount = 0;
  let i = text.length - 1;

  while (i >= 0) {
    const ch = text[i]!;
    if (ch === ")") depth++;
    else if (ch === "(") {
      if (depth === 0) {
        // Found the matching open paren
        // Get the function name before it
        let nameEnd = i;
        let nameStart = i - 1;
        while (nameStart >= 0 && isIdentChar(text[nameStart]!)) nameStart--;
        nameStart++;
        const name = text.slice(nameStart, nameEnd);
        const isDot = nameStart > 0 && text[nameStart - 1] === ".";
        if (name) {
          return { name, commaCount, isDot };
        }
        return null;
      }
      depth--;
    } else if (ch === "," && depth === 0) {
      commaCount++;
    }
    i--;
  }

  return null;
}

function parseMethodParams(
  signature: string
): Array<{
  name: string;
  type: string;
  optional?: boolean;
  description?: string;
}> {
  // Parse params from signature like ".within(geometry: Area | Polygon | Isochrone)"
  const match = signature.match(/\(([^)]*)\)/);
  if (!match || !match[1]) return [];

  return match[1].split(",").map((p) => {
    const trimmed = p.trim();
    const [name, ...typeParts] = trimmed.split(":");
    return {
      name: (name ?? "").trim(),
      type: typeParts.join(":").trim(),
    };
  });
}

function isIdentChar(ch: string): boolean {
  return (
    (ch >= "a" && ch <= "z") ||
    (ch >= "A" && ch <= "Z") ||
    (ch >= "0" && ch <= "9") ||
    ch === "_"
  );
}
