import type { Statement } from "./types.js";
export interface ParseError {
    line: number;
    col: number;
    message: string;
}
export interface ParseResult {
    ast: Statement[];
    errors: ParseError[];
}
export declare function parse(source: string): ParseResult;
