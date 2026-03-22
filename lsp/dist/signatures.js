"use strict";
// PlazaQL signature help provider
Object.defineProperty(exports, "__esModule", { value: true });
exports.getSignatureHelp = getSignatureHelp;
const types_js_1 = require("./types.js");
function getSignatureHelp(source, line, col) {
    const lines = source.split("\n");
    const currentLine = lines[line - 1];
    if (!currentLine)
        return null;
    const textBefore = currentLine.slice(0, col - 1);
    // Find the innermost open function/method call
    const callInfo = findOpenCall(textBefore);
    if (!callInfo)
        return null;
    const { name, commaCount, isDot } = callInfo;
    // Look up function signature
    let sig;
    if (isDot) {
        // Method call — find in METHOD_CATALOG
        const method = types_js_1.METHOD_CATALOG.find((m) => m.name === name);
        if (method) {
            // Build a pseudo-signature from the catalog
            sig = {
                name: "." + method.name,
                params: parseMethodParams(method.signature),
                returnType: "same type",
                description: method.description,
            };
        }
    }
    else {
        sig = types_js_1.FUNCTION_SIGNATURES[name];
    }
    if (!sig)
        return null;
    const paramLabels = sig.params.map((p) => `${p.name}${p.optional ? "?" : ""}: ${p.type}`);
    const sigLabel = `${sig.name}(${paramLabels.join(", ")})`;
    const parameters = sig.params.map((p) => ({
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
function findOpenCall(text) {
    // Walk backwards to find the open paren
    let depth = 0;
    let commaCount = 0;
    let i = text.length - 1;
    while (i >= 0) {
        const ch = text[i];
        if (ch === ")")
            depth++;
        else if (ch === "(") {
            if (depth === 0) {
                // Found the matching open paren
                // Get the function name before it
                let nameEnd = i;
                let nameStart = i - 1;
                while (nameStart >= 0 && isIdentChar(text[nameStart]))
                    nameStart--;
                nameStart++;
                const name = text.slice(nameStart, nameEnd);
                const isDot = nameStart > 0 && text[nameStart - 1] === ".";
                if (name) {
                    return { name, commaCount, isDot };
                }
                return null;
            }
            depth--;
        }
        else if (ch === "," && depth === 0) {
            commaCount++;
        }
        i--;
    }
    return null;
}
function parseMethodParams(signature) {
    // Parse params from signature like ".within(geometry: Area | Polygon | Isochrone)"
    const match = signature.match(/\(([^)]*)\)/);
    if (!match || !match[1])
        return [];
    return match[1].split(",").map((p) => {
        const trimmed = p.trim();
        const [name, ...typeParts] = trimmed.split(":");
        return {
            name: (name ?? "").trim(),
            type: typeParts.join(":").trim(),
        };
    });
}
function isIdentChar(ch) {
    return ((ch >= "a" && ch <= "z") ||
        (ch >= "A" && ch <= "Z") ||
        (ch >= "0" && ch <= "9") ||
        ch === "_");
}
//# sourceMappingURL=signatures.js.map