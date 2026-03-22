import type { PqlType, Expr, Statement } from "./types.js";
export interface TypeCheckError {
    line: number;
    col: number;
    message: string;
    hint?: string;
    severity: "error" | "warning";
}
export interface VarInfo {
    type: PqlType;
    line: number;
    col: number;
    expr: Expr;
}
export type Scope = Map<string, VarInfo>;
export interface TypeCheckResult {
    errors: TypeCheckError[];
    scope: Scope;
    /** Type of each statement's expression (indexed by statement index) */
    stmtTypes: (PqlType | null)[];
}
export declare function typeCheck(ast: Statement[]): TypeCheckResult;
export declare function inferExprType(expr: Expr, scope: Scope): PqlType;
export declare function getExprAtPosition(ast: Statement[], line: number, col: number): {
    expr: Expr | null;
    scope: Scope;
};
