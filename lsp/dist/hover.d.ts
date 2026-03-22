export interface HoverResult {
    contents: string;
    range?: {
        startLine: number;
        startCol: number;
        endLine: number;
        endCol: number;
    };
}
export declare function getHover(source: string, line: number, col: number): HoverResult | null;
