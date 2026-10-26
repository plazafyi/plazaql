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

  it("accepts spatial after transform (relaxed ordering)", () => {
    const result = check(
      '$$ =search().buffer(100).within(boundary(name: "Berlin"));'
    );
    expect(result.errors).toHaveLength(0);
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
      '$b = boundary(name: "Berlin");\n$$ =search().within($b);'
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

  // ── .simplify() ────────────────────────────────────────────────

  it("accepts .simplify() on PointSet", () => {
    const result = check('$$ =search(node, amenity: "cafe").simplify(10);');
    expect(result.errors).toHaveLength(0);
  });

  it("accepts .simplify() on GeoSet", () => {
    const result = check("$$ =search(way).simplify(100);");
    expect(result.errors).toHaveLength(0);
  });

  // ── .sort() accepts any expression ─────────────────────────

  it("accepts .sort(distance) without .around()", () => {
    const result = check("$$ =search().sort(distance);");
    expect(result.errors).toHaveLength(0);
  });

  it("accepts .sort(by: :distance) with .around()", () => {
    const result = check(
      "$$ =search().around(500, point(38.9, -77.0)).sort(by: :distance);"
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

  it("infers Boundary type for boundary()", () => {
    const result = check('$b = boundary(name: "Berlin");\n$$ =search().within($b);');
    expect(result.errors).toHaveLength(0);
    expect(result.scope.get("$b")?.type).toBe("Boundary");
  });

  // ── Computation type inference ─────────────────────────────────

  it("infers Route type for route()", () => {
    const result = check(
      "$$ =route(origin: point(0, 0), destination: point(1, 1));"
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

  // ── Relaxed ordering tests ──────────────────────────────────────

  it("accepts filter after transform (relaxed ordering)", () => {
    const result = check('$$ =search(node, amenity: "cafe").buffer(50).filter(cuisine: "italian");');
    expect(result.errors).toHaveLength(0);
  });

  it("accepts computed method before transform (relaxed ordering)", () => {
    const result = check('$$ =search(node, amenity: "cafe").elevation().buffer(50);');
    expect(result.errors).toHaveLength(0);
  });

  it("rejects spatial after ordering", () => {
    const result = check('$$ =search().limit(10).within(boundary(name: "Berlin"));');
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("cannot follow"))).toBe(true);
  });

  it("rejects anything after output mode", () => {
    const result = check('$$ =search(node, amenity: "cafe").count().limit(10);');
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.message.includes("cannot follow"))).toBe(true);
  });

  it("accepts centroid then simplify (relaxed type restriction)", () => {
    const result = check('$$ =search(way, building: "yes").centroid().simplify(10);');
    expect(result.errors).toHaveLength(0);
  });

  // ── centroid() and expansion() ─────────────────────────────────

  describe("truck options", () => {
    const route = "origin: point(40.71, -74.00), destination: point(40.75, -73.98)";

    it("accepts the vehicle on route, isochrone and matrix with mode truck", () => {
      for (const src of [
        `$$ = route(${route}, mode: "truck", height: 4.1, width: 2.5, length: 16.5, weight: 30, axle_load: 9.5, axle_count: 5, hazmat: true);`,
        '$$ = isochrone(center: point(40.71, -74.00), time: 600, mode: "truck", height: 3.8);',
        '$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], mode: "truck", weight: 40);',
      ]) {
        expect(check(src).errors).toHaveLength(0);
      }
    });

    it("needs mode truck", () => {
      const result = check(`$$ = route(${route}, height: 4.1);`);
      expect(result.errors.some((e) => e.message.includes('need `mode: "truck"`'))).toBe(true);
    });

    it("rejects truck options on other computations", () => {
      const result = check(
        '$$ = centroid(locations: [point(48.858, 2.294), point(48.87, 2.35)], height: 4.0);'
      );
      expect(result.errors.some((e) => e.message.includes("`centroid()` has no truck options"))).toBe(true);
    });

    it("checks value types like the Elixir type checker", () => {
      const messages = (src: string) => check(src).errors.map((e) => e.message);
      expect(messages(`$$ = route(${route}, mode: "truck", height: "tall");`)).toContain(
        "`height:` must be a positive number (metres)"
      );
      expect(messages(`$$ = route(${route}, mode: "truck", weight: 0);`)).toContain(
        "`weight:` must be a positive number (tonnes)"
      );
      expect(messages(`$$ = route(${route}, mode: "truck", axle_count: 2.5);`)).toContain(
        "`axle_count:` must be a whole number of axles"
      );
      expect(messages(`$$ = route(${route}, mode: "truck", hazmat: "yes");`)).toContain(
        "`hazmat:` must be `true` or `false`"
      );
    });
  });

  describe("centroid()", () => {
    const locations = "locations: [point(48.858, 2.294), point(48.87, 2.35)]";

    it("is a PointSet usable as a geometry", () => {
      const result = check(
        `$m = centroid(${locations}, metric: "distance"); $$ = search(node, amenity: "cafe").around(300, $m);`
      );
      expect(result.errors).toHaveLength(0);
    });

    it("rejects an unknown metric", () => {
      const result = check(`$$ = centroid(${locations}, metric: "vibes");`);
      expect(result.errors.some((e) => e.message.includes("`metric:` must be one of"))).toBe(true);
    });
  });

  describe("expansion()", () => {
    const route = "origin: point(48.858, 2.294), destination: point(48.87, 2.35)";

    it("accepts each action", () => {
      for (const src of [
        `$$ = expansion(action: "route", ${route}, expansion_properties: ["duration", "distance"]);`,
        '$$ = expansion(action: "isochrone", center: point(48.858, 2.294), time: 600);',
        '$$ = expansion(action: "matrix", origins: [point(48.858, 2.294)], destinations: [point(48.87, 2.35)]);',
      ]) {
        expect(check(src).errors).toHaveLength(0);
      }
    });

    it("requires a known action", () => {
      expect(
        check(`$$ = expansion(${route});`).errors.some((e) => e.message.includes("requires `action:`"))
      ).toBe(true);
      expect(
        check(`$$ = expansion(action: "teleport", ${route});`).errors.some((e) =>
          e.message.includes("`action:` must be one of")
        )
      ).toBe(true);
    });

    it("rejects unknown expansion_properties", () => {
      const result = check(
        `$$ = expansion(action: "route", ${route}, expansion_properties: ["vibes"]);`
      );
      expect(result.errors.some((e) => e.message.includes('"vibes"'))).toBe(true);
    });
  });
});
