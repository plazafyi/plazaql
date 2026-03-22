export interface CompletionItem {
    label: string;
    kind: "method" | "variable" | "keyword" | "tag" | "function" | "param";
    detail?: string;
    documentation?: string;
    insertText?: string;
    sortText?: string;
}
export interface CompletionContext {
    triggerChar: string | null;
    line: number;
    col: number;
}
export declare function getCompletions(source: string, line: number, col: number): CompletionItem[];
