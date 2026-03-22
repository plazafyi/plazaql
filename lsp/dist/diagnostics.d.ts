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
export declare function getDiagnostics(source: string): Diagnostic[];
