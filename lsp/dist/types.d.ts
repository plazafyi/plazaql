export type PqlType = "Point" | "LineString" | "Polygon" | "PointSet" | "LineSet" | "PolygonSet" | "GeoSet" | "Route" | "Isochrone" | "Area" | "Matrix" | "Elevation" | "Scalar";
export declare function isGeometric(type: PqlType): boolean;
export declare function isGeoSet(type: PqlType): boolean;
export declare function isChainable(type: PqlType): boolean;
export declare function isTerminal(type: PqlType): boolean;
export declare function unionType(a: PqlType, b: PqlType): PqlType;
export interface Pos {
    line: number;
    col: number;
}
export type ElementType = "node" | "way" | "relation" | "nwr" | "nw" | "nr" | "wr";
export type TagFilterOp = "eq" | "neq" | "regex" | "regex_i" | "not_regex" | "exists" | "not_exists";
export interface TagFilter {
    op: TagFilterOp;
    key: string;
    value?: string;
}
export interface NumberNode {
    kind: "number";
    value: number;
    pos: Pos;
}
export interface StringNode {
    kind: "string";
    value: string;
    pos: Pos;
}
export interface BoolNode {
    kind: "bool";
    value: boolean;
    pos: Pos;
}
export interface AtomNode {
    kind: "atom";
    value: string;
    pos: Pos;
}
export interface IdentifierNode {
    kind: "identifier";
    name: string;
    pos: Pos;
}
export interface VarRefNode {
    kind: "var_ref";
    name: string;
    pos: Pos;
}
export interface PointNode {
    kind: "point";
    lat: number | null;
    lng: number | null;
    args: Arg[];
    pos: Pos;
}
export interface BboxNode {
    kind: "bbox";
    s: number | null;
    w: number | null;
    n: number | null;
    e: number | null;
    args: Arg[];
    pos: Pos;
}
export interface GeometryNode {
    kind: "linestring" | "polygon" | "circle";
    items: Expr[];
    pos: Pos;
}
export interface SearchNode {
    kind: "search";
    elementType: ElementType | null;
    filters: TagFilter[];
    methods: MethodNode[];
    pos: Pos;
}
export interface AreaNode {
    kind: "area";
    filters: TagFilter[];
    pos: Pos;
}
export interface ComputationNode {
    kind: "computation";
    name: ComputationName;
    args: Arg[];
    pos: Pos;
}
export type ComputationName = "route" | "isochrone" | "geocode" | "reverse_geocode" | "autocomplete" | "text_search" | "matrix" | "map_match" | "optimize" | "ev_route" | "elevation" | "elevation_profile" | "nearest";
export interface MethodNode {
    kind: "method";
    name: string;
    args: Arg[] | TagFilter[];
    pos: Pos;
}
export interface ChainNode {
    kind: "chain";
    receiver: Expr;
    method: MethodNode;
    pos: Pos;
}
export interface ArrowChainNode {
    kind: "arrow_chain";
    items: Expr[];
    pos: Pos;
}
export interface UnionNode {
    kind: "union";
    left: Expr;
    right: Expr;
    pos: Pos;
}
export interface DifferenceNode {
    kind: "difference";
    left: Expr;
    right: Expr;
    pos: Pos;
}
export interface ListNode {
    kind: "list";
    items: Expr[];
    pos: Pos;
}
export interface SettingsNode {
    kind: "settings";
    pairs: Array<{
        key: string;
        value: string | number | boolean;
    }>;
    pos: Pos;
}
export interface VarAssignNode {
    kind: "var_assign";
    name: string;
    expr: Expr;
    pos: Pos;
}
export interface OutputNode {
    kind: "output";
    name: string | null;
    expr: Expr;
    pos: Pos;
}
export type KwArg = {
    type: "kwarg";
    name: string;
    value: Expr;
};
export type PosArg = {
    type: "posarg";
    value: Expr;
};
export type Arg = KwArg | PosArg;
export type Expr = NumberNode | StringNode | BoolNode | AtomNode | IdentifierNode | VarRefNode | PointNode | BboxNode | GeometryNode | SearchNode | AreaNode | ComputationNode | ChainNode | ArrowChainNode | UnionNode | DifferenceNode | ListNode;
export type Statement = SettingsNode | VarAssignNode | OutputNode;
export type AstNode = Statement | Expr;
export type MethodPhase = {
    ordinal: number;
    label: string;
};
export declare const ALL_METHODS: string[];
export declare function methodPhase(method: string): MethodPhase;
export declare function isOutputMode(method: string): boolean;
export declare function isSpatialMethod(method: string): boolean;
export declare function methodOutputType(method: string, inputType: PqlType): {
    ok: true;
    type: PqlType;
} | {
    ok: false;
    error: string;
};
export declare function validSpatialArgTypes(method: string): PqlType[];
export declare function computationType(name: string): PqlType;
export declare function searchBaseType(elemType: ElementType | null): PqlType;
export interface MethodInfo {
    name: string;
    signature: string;
    description: string;
    phase: string;
    ordinal: number;
}
export declare const METHOD_CATALOG: MethodInfo[];
export declare const COMMON_TAG_KEYS: string[];
export interface ParamInfo {
    name: string;
    type: string;
    optional?: boolean;
    description?: string;
}
export interface FunctionSignature {
    name: string;
    params: ParamInfo[];
    returnType: string;
    description: string;
}
export declare const FUNCTION_SIGNATURES: Record<string, FunctionSignature>;
