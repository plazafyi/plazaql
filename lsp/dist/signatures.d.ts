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
export declare function getSignatureHelp(source: string, line: number, col: number): SignatureHelp | null;
