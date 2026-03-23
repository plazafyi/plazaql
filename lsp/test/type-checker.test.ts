import { describe, it, expect } from "vitest";
import { parse } from "../src/parser.js";
import { typeCheck } from "../src/type-checker.js";

function check(source: string) {
  const { ast, errors: parseErrors } = parse(source);
  expect(parseErrors).toHaveLength(0);
  return typeCheck(ast);
}

describe("PlazaQL Type Checker", () => {
  // ── Valid chain ordering ───────────────────────────────────────

  it("accepts valid chain ordering", () => {
    const result = check(
      '$$ =search(node, amenity: "cafe").around(500, point(38.9, -77.0)).sort(distance).limit(10);'
    );
    expect(result.errors).toHaveLength(0);
  });

  // ── Invalid chain ordering ─────────────────────────────────────

  it("rejects transform after ordering", () => {
    const result = check("$$ =search().limit(10).buffer(100);");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("cannot follow"))).toBe(true);
  });

  it("rejects spatial after transform", () => {
    const result = check(
      "$$ =search().buffer(100).within(area(name: \"Berlin\"));"
    );
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("cannot follow"))).toBe(true);
  });

  // ── Type inference for search ──────────────────────────────────

  it("infers PointSet for search(node)", () => {
    const result = check("$$ =search(node).limit(10);");
    expect(result.errors).toHaveLength(0);
    expect(result.stmtTypes[0]).toBe("PointSet");
  });

  it("infers GeoSet for search() without type", () => {
    const result = check("$$ =search().limit(10);");
    expect(result.errors).toHaveLength(0);
    expect(result.stmtTypes[0]).toBe("GeoSet");
  });

  it("infers GeoSet for search(way)", () => {
    const result = check("$$ =search(way).limit(10);");
    expect(result.errors).toHaveLength(0);
    expect(result.stmtTypes[0]).toBe("GeoSet");
  });

  // ── .within() requires Area/Polygon ────────────────────────────

  it("accepts .within() with area variable", () => {
    const result = check(
      '$b = area(name: "Berlin");\n$$ =search().within($b);'
    );
    expect(result.errors).toHaveLength(0);
  });

  it("rejects .within() with Point variable", () => {
    const result = check(
      "$p = point(38.9, -77.0);\n$$ =search().within($p);"
    );
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("requires"))).toBe(true);
  });

  // ── .simplify() not on PointSet ────────────────────────────────

  it("rejects .simplify() on PointSet (search node)", () => {
    const result = check("$$ =search(node).simplify(100);");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("simplify"))).toBe(true);
  });

  it("accepts .simplify() on GeoSet", () => {
    const result = check("$$ =search(way).simplify(100);");
    expect(result.errors).toHaveLength(0);
  });

  // ── .sort(distance) requires .around() ─────────────────────────

  it("rejects .sort(distance) without .around()", () => {
    const result = check("$$ =search().sort(distance);");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("spatial reference"))).toBe(true);
  });

  it("accepts .sort(distance) with .around()", () => {
    const result = check(
      "$$ =search().around(500, point(38.9, -77.0)).sort(distance);"
    );
    expect(result.errors).toHaveLength(0);
  });

  // ── .offset() requires .limit() ───────────────────────────────

  it("rejects .offset() without .limit()", () => {
    const result = check("$$ =search().offset(10);");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("limit"))).toBe(true);
  });

  it("accepts .offset() with .limit()", () => {
    const result = check("$$ =search().limit(20).offset(10);");
    expect(result.errors).toHaveLength(0);
  });

  // ── Undefined variable ─────────────────────────────────────────

  it("reports undefined variable", () => {
    const result = check("$$ =$nonexistent;");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("undefined variable"))).toBe(true);
  });

  // ── Duplicate variable ─────────────────────────────────────────

  it("reports duplicate variable", () => {
    const result = check(
      "$a = search();\n$a = search();\n$$ =$a;"
    );
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("duplicate"))).toBe(true);
  });

  // ── Union type inference ───────────────────────────────────────

  it("infers GeoSet for union of different types", () => {
    const result = check(
      "$a = search(node);\n$b = search(way);\n$$ =$a + $b;"
    );
    expect(result.errors).toHaveLength(0);
    // PointSet + GeoSet = GeoSet
    expect(result.stmtTypes[2]).toBe("GeoSet");
  });

  it("preserves type for union of same types", () => {
    const result = check(
      "$a = search(node);\n$b = search(node);\n$$ =$a + $b;"
    );
    expect(result.errors).toHaveLength(0);
    expect(result.stmtTypes[2]).toBe("PointSet");
  });

  // ── .centroid() changes type ───────────────────────────────────

  it(".centroid() changes type to PointSet", () => {
    const result = check("$$ =search(way).centroid();");
    expect(result.errors).toHaveLength(0);
    expect(result.stmtTypes[0]).toBe("PointSet");
  });

  // ── .buffer() changes type ─────────────────────────────────────

  it(".buffer() changes type to PolygonSet", () => {
    const result = check("$$ =search(node).buffer(100);");
    expect(result.errors).toHaveLength(0);
    expect(result.stmtTypes[0]).toBe("PolygonSet");
  });

  // ── .count() produces Scalar ───────────────────────────────────

  it(".count() produces Scalar", () => {
    const result = check("$$ =search().count();");
    expect(result.errors).toHaveLength(0);
    expect(result.stmtTypes[0]).toBe("Scalar");
  });

  // ── Method on terminal type ────────────────────────────────────

  it("rejects method on Scalar (terminal)", () => {
    const result = check("$$ =search().count().limit(10);");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("terminal"))).toBe(true);
  });

  it("rejects method on Matrix (terminal)", () => {
    const result = check(
      "$$ =matrix(point(0, 0), point(1, 1)).limit(10);"
    );
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("terminal"))).toBe(true);
  });

  // ── Output required ────────────────────────────────────────────

  it("requires at least one output", () => {
    const result = check("$a = search();");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("output"))).toBe(true);
  });

  // ── Multiple output modes ──────────────────────────────────────

  it("rejects multiple output modes", () => {
    const result = check("$$ =search().count().ids();");
    // count() makes it Scalar which is terminal, so it'll get terminal error
    expect(result.errors.length).toBeGreaterThan(0);
  });

  // ── Area type inference ────────────────────────────────────────

  it("infers Area type for area()", () => {
    const result = check('$b = area(name: "Berlin");\n$$ =search().within($b);');
    expect(result.errors).toHaveLength(0);
    expect(result.scope.get("$b")?.type).toBe("Area");
  });

  // ── Computation type inference ─────────────────────────────────

  it("infers Route type for route()", () => {
    const result = check(
      "$$ =route(point(0, 0) -> point(1, 1));"
    );
    expect(result.errors).toHaveLength(0);
    expect(result.stmtTypes[0]).toBe("Route");
  });

  it("infers Isochrone type for isochrone()", () => {
    const result = check("$$ =isochrone(point(0, 0), time: 600);");
    expect(result.errors).toHaveLength(0);
    expect(result.stmtTypes[0]).toBe("Isochrone");
  });

  // ── Mixed output validation ───────────────────────────────────

  it("rejects multiple simple $$ outputs", () => {
    const result = check("$$ = search();\n$$ = search(node);");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("only one"))).toBe(true);
  });

  it("rejects mixing simple $$ and named $$.name outputs", () => {
    const result = check("$$ = search();\n$$.cafes = search();");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("cannot mix"))).toBe(true);
  });

  it("allows multiple named $$.name outputs", () => {
    const result = check("$$.cafes = search();\n$$.parks = search();");
    expect(result.errors).toHaveLength(0);
  });

  // ── Bare expression output ──────────────────────────────────

  it("accepts bare expression as output", () => {
    const result = check('search(amenity: "cafe");');
    expect(result.errors).toHaveLength(0);
  });

  it("accepts bare expression with method chain", () => {
    const result = check('search(node, amenity: "cafe").limit(10);');
    expect(result.errors).toHaveLength(0);
  });

  it("rejects multiple bare outputs", () => {
    const result = check("search();\nsearch(node);");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("only one"))).toBe(true);
  });

  it("rejects mixing bare output and named output", () => {
    const result = check('search();\n$$.cafes = search(amenity: "cafe");');
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("cannot mix"))).toBe(true);
  });

  it("rejects mixing bare output and explicit $$ output", () => {
    const result = check("search();\n$$ = search(node);");
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("only one"))).toBe(true);
  });
});
