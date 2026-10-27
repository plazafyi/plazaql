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

  // ── .cursor() ─────────────────────────────────────────────────

  it("accepts .cursor() with a token string", () => {
    const result = check('$$ =search().limit(20).cursor("SFMyNTY.g2gD.x-_y");');
    expect(result.errors).toHaveLength(0);
  });

  it("rejects .cursor() combined with .offset()", () => {
    for (const source of [
      '$$ =search().limit(20).offset(10).cursor("abc");',
      '$$ =search().limit(20).cursor("abc").offset(10);',
    ]) {
      const result = check(source);
      expect(result.errors.map((e) => e.message)).toContain(
        "`.cursor()` and `.offset()` cannot be combined"
      );
    }
  });

  it("rejects .cursor() without exactly one string", () => {
    for (const source of [
      "$$ =search().limit(20).cursor(5);",
      "$$ =search().limit(20).cursor();",
    ]) {
      const result = check(source);
      expect(
        result.errors.some((e) => e.message.includes("`.cursor()` takes one string"))
      ).toBe(true);
    }
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

  describe("road departure, distance isochrones and batch reverse geocoding", () => {
    const messages = (src: string) => check(src).errors.map((e) => e.message);

    it("accepts depart_at and traffic_model on isochrone and matrix", () => {
      expect(
        messages(
          '$$ = isochrone(center: point(40.71, -74.00), time: 600, depart_at: "2026-03-16T08:00:00-04:00", traffic_model: "pessimistic");'
        )
      ).toEqual([]);
      expect(
        messages(
          '$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], depart_at: "now", traffic_model: "optimistic");'
        )
      ).toEqual([]);
    });

    it("takes a distance budget on isochrone, not with time", () => {
      expect(messages("$$ = isochrone(center: point(40.71, -74.00), distance: [1000, 2000]);")).toEqual([]);
      expect(messages("$$ = isochrone(center: point(40.71, -74.00), time: 600, distance: 2000);")).toEqual([
        "`time:` and `distance:` can't be combined",
      ]);
    });

    it("accepts points on reverse_geocode", () => {
      expect(messages("$$ = reverse_geocode(points: [point(40.71, -74.00), point(40.75, -73.98)]);")).toEqual([]);
    });
  });

  describe("transit options", () => {
    const route = "origin: point(40.71, -74.00), destination: point(40.75, -73.98)";

    it("accepts the transit options on route and isochrone with mode transit", () => {
      for (const src of [
        `$$ = route(${route}, mode: "transit", depart_at: "2026-03-16T08:00:00-04:00", use_bus: 0.5, use_rail: 1, use_transfers: 0, max_walk_m: 800, max_transfers: 2);`,
        '$$ = isochrone(center: point(40.71, -74.00), time: [900, 1800], mode: "transit", depart_at: "now", max_walk_m: 500);',
        `$$ = route(${route}, mode: "transit", max_transfers: 2.0);`,
      ]) {
        expect(check(src).errors).toHaveLength(0);
      }
    });

    it("needs mode transit", () => {
      const result = check(`$$ = route(${route}, mode: "foot", use_bus: 0);`);
      expect(result.errors.some((e) => e.message.includes('need `mode: "transit"`'))).toBe(true);
      const fromVar = check(`$m = "transit"; $$ = route(${route}, mode: $m, use_rail: 0.5);`);
      expect(fromVar.errors.some((e) => e.message.includes("transit options"))).toBe(false);
    });

    it("checks arrive_by like the Elixir type checker", () => {
      const messages = (src: string) => check(src).errors.map((e) => e.message);
      expect(messages(`$$ = route(${route}, mode: "transit", arrive_by: "2026-03-16T09:00:00-04:00");`)).toEqual([]);
      expect(messages(`$$ = route(${route}, mode: "transit", arrive_by: "2026-03-16T09:00:00");`)).toEqual([]);
      expect(
        messages(`$$ = route(${route}, mode: "foot", arrive_by: "2026-03-16T09:00:00Z");`).some((m) =>
          m.includes('need `mode: "transit"`')
        )
      ).toBe(true);
      expect(messages(`$$ = route(${route}, mode: "transit", depart_at: "now", arrive_by: "2026-03-16T09:00:00Z");`)).toEqual([
        "`depart_at:` and `arrive_by:` can't be combined",
      ]);
      for (const value of ['"now"', "9", "true"]) {
        expect(messages(`$$ = route(${route}, mode: "transit", arrive_by: ${value});`)).toEqual([
          "`arrive_by:` must be an ISO 8601 datetime string",
        ]);
      }
      expect(
        messages(
          '$$ = isochrone(center: point(40.71, -74.00), time: 600, mode: "transit", arrive_by: "2026-03-16T09:00:00Z");'
        )
      ).toEqual(["`arrive_by:` is supported by transit routes, not isochrones"]);
    });

    it("accepts wheelchair with mode transit", () => {
      const messages = (src: string) => check(src).errors.map((e) => e.message);
      expect(messages(`$$ = route(${route}, mode: "transit", wheelchair: true, max_walk_m: 500);`)).toEqual([]);
      expect(
        messages('$$ = isochrone(center: point(40.71, -74.00), time: 900, mode: "transit", wheelchair: false);')
      ).toEqual([]);
      expect(messages(`$$ = route(${route}, mode: "auto", wheelchair: true);`)).toEqual([
        '`wheelchair:` need `mode: "foot"` or `mode: "transit"`',
      ]);
      expect(messages(`$$ = route(${route}, mode: "transit", wheelchair: 1);`)).toEqual([
        "`wheelchair:` must be `true` or `false`",
      ]);
      // Pedestrian options apply to the walking legs of a transit journey.
      expect(messages(`$$ = route(${route}, mode: "transit", wheelchair: true, walking_speed: 4, use_lit: 1);`)).toEqual([]);
      expect(
        messages('$$ = isochrone(center: point(40.71, -74.00), time: 900, mode: "transit", walking_speed: 3);')
      ).toEqual([]);
      expect(messages(`$$ = route(${route}, mode: "transit", walking_speed: 20);`)).toContain(
        "`walking_speed:` must be a number from 1 to 10 (km/h)"
      );
    });

    it("rejects transit options on other computations", () => {
      const result = check(
        "$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], max_transfers: 1);"
      );
      expect(result.errors.some((e) => e.message.includes("`matrix()` has no transit options"))).toBe(true);
    });

    it("checks value types like the Elixir type checker", () => {
      const messages = (src: string) => check(src).errors.map((e) => e.message);
      expect(messages(`$$ = route(${route}, mode: "transit", use_bus: 2);`)).toContain(
        "`use_bus:` must be a number from 0 to 1"
      );
      expect(messages(`$$ = route(${route}, mode: "transit", max_walk_m: "far");`)).toContain(
        "`max_walk_m:` must be a non-negative number of meters"
      );
      expect(messages(`$$ = route(${route}, mode: "transit", max_transfers: 1.5);`)).toContain(
        "`max_transfers:` must be a whole number"
      );
    });
  });

  describe("costing options", () => {
    const route = "origin: point(40.71, -74.00), destination: point(40.75, -73.98)";
    const messages = (src: string) => check(src).errors.map((e) => e.message);

    it("accepts them on route, ev_route and matrix, and the speeds on isochrone", () => {
      for (const src of [
        `$$ = route(${route}, use_highways: 0.2, use_tolls: 0, use_ferries: 1, use_living_streets: 0.5, top_speed: 100, fixed_speed: 60, maneuver_penalty: 5, service_penalty: 15, gate_cost: 60, toll_booth_cost: 120, country_crossing_cost: 600);`,
        `$$ = route(${route}, mode: "foot", use_tracks: 1, shortest: true);`,
        `$$ = route(${route}, waypoints: [point(40.72, -74.00)], location_types: ["break", "through", "break"], headings: [90, 0, 180], heading_tolerances: "45;;", preferred_sides: ["", "", "same"], approaches: ";;curb", recostings: ["no_tolls: use_tolls=0", "walk: mode=foot"]);`,
        "$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], use_tolls: 0);",
        "$$ = ev_route(origin: point(40.71, -74.00), destination: point(42.36, -71.06), battery: 60000, use_tolls: 0);",
        "$$ = isochrone(center: point(40.71, -74.00), time: 600, top_speed: 50);",
      ]) {
        expect(check(src).errors, src).toHaveLength(0);
      }
      expect(messages("$$ = isochrone(center: point(40.71, -74.00), time: 600, use_tolls: 0);")).toContain(
        "`isochrone()` does not accept `use_tolls:`"
      );
    });

    it("checks value shapes like the Elixir type checker", () => {
      for (const [kwargs, message] of [
        ["use_tolls: 2", "`use_tolls:` must be a number from 0 (avoid) through 0.5 (neutral) to 1 (prefer)"],
        ["shortest: 1", "`shortest:` must be true or false"],
        ["top_speed: 5", "`top_speed:` must be a speed cap in whole km/h from 10 to 252"],
        ["maneuver_penalty: -1", "`maneuver_penalty:` must be seconds from 0 to 3600"],
        ["gate_cost: 3601", "`gate_cost:` must be seconds from 0 to 3600"],
        ['toll_booth_cost: "1"', "`toll_booth_cost:` must be seconds from 0 to 3600"],
        ["country_crossing_cost: -5", "`country_crossing_cost:` must be seconds from 0 to 3600"],
        [
          'location_types: ["stop", "break"]',
          '`location_types:` must be one entry per point (origin, waypoints, destination): "break", "through" or "via", or a ";"-separated string',
        ],
        [
          'approaches: ["kerb", ""]',
          '`approaches:` must be one entry per point (origin, waypoints, destination): "unrestricted" or "curb", or a ";"-separated string',
        ],
        ["headings: [400, 0]", "`headings:` must be a heading in degrees from 0 to 360 per point, or a \";\"-separated string with empty entries for points without one"],
        ["recostings: [1]", '`recostings:` must be a list of strings such as ["no_tolls: use_tolls=0", "walk: mode=foot"]'],
      ]) {
        expect(messages(`$$ = route(${route}, ${kwargs});`), kwargs).toContain(message);
      }
    });
  });

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

    it("leaves a mode from a variable to the server", () => {
      const result = check(`$m = "truck"; $$ = route(${route}, mode: $m, height: 4.1);`);
      expect(result.errors.some((e) => e.message.includes("truck options"))).toBe(false);
    });

    it("accepts a whole-number axle_count written as 5.0", () => {
      const result = check(`$$ = route(${route}, mode: "truck", axle_count: 5.0);`);
      expect(result.errors).toHaveLength(0);
    });

    it("rejects truck options on other computations", () => {
      const result = check(`$$ = nearest(point(48.858, 2.294), height: 4.0);`);
      expect(
        result.errors.some((e) =>
          e.message.includes(
            "`nearest()` has no truck options; they apply to `route()`, `isochrone()`, `matrix()`, `optimize()`, `centroid()`, `expansion()`, `map_match()` and `ev_route()`"
          )
        )
      ).toBe(true);
    });

    it("accepts truck options on ev_route with mode truck", () => {
      const result = check(`$$ = ev_route(origin: point(48.858, 2.294), destination: point(48.87, 2.35), battery: 600000, mode: "truck", weight: 40, height: 4.0);`);
      expect(result.errors).toHaveLength(0);
      const noMode = check(`$$ = ev_route(origin: point(48.858, 2.294), destination: point(48.87, 2.35), battery: 60000, height: 4.0);`);
      expect(noMode.errors.some((e) => e.message.includes('need `mode: "truck"`'))).toBe(true);
    });

    it("accepts optimize time windows, service times and capacity", () => {
      const src =
        '$$ = optimize(waypoints: [point(1, 2), point(3, 4)], time_windows: ["", [0, 600]], service_s: 60, demands: [0, 2], capacity: 4, depart_at: "2026-11-02T08:00:00Z");';
      expect(check(src).errors).toHaveLength(0);
      expect(
        check('$$ = route(origin: point(1, 2), destination: point(3, 4), capacity: 4);').errors.some((e) =>
          e.message.includes("does not accept `capacity:`"),
        ),
      ).toBe(true);
    });

    it("accepts truck options on optimize, centroid, expansion and map_match", () => {
      const a = "point(48.858, 2.294)";
      const b = "point(48.87, 2.35)";
      for (const src of [
        `$$ = optimize(waypoints: [${a}, ${b}], mode: "truck", height: 4.0);`,
        `$$ = centroid(locations: [${a}, ${b}], mode: "truck", height: 4.0, hazmat: true);`,
        `$$ = expansion(action: "route", origin: ${a}, destination: ${b}, mode: "truck", weight: 30);`,
        `$$ = map_match(points: [${a}, ${b}], mode: "truck", axle_count: 5);`,
      ]) {
        expect(check(src).errors).toHaveLength(0);
      }
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

  describe("bicycle and pedestrian options", () => {
    const route = "origin: point(40.71, -74.00), destination: point(40.75, -73.98)";
    const messages = (src: string) => check(src).errors.map((e) => e.message);

    it("accepts rider and walker options on route, isochrone and matrix", () => {
      for (const src of [
        `$$ = route(${route}, mode: "bicycle", bicycle_type: "road", cycling_speed: 24, use_roads: 0.2, use_hills: 0.1, avoid_bad_surfaces: 1);`,
        `$$ = route(${route}, mode: "foot", walking_speed: 4, use_hills: 0.5, use_lit: 1, walkway_factor: 0.8, sidewalk_factor: 0.9, step_penalty: 60, max_hiking_difficulty: 3.0, wheelchair: true);`,
        '$$ = isochrone(center: point(40.71, -74.00), time: 600, mode: "walk", wheelchair: true);',
        '$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], mode: "bike", use_hills: 0);',
      ]) {
        expect(check(src).errors).toHaveLength(0);
      }
    });

    it("needs the matching mode", () => {
      expect(messages(`$$ = route(${route}, bicycle_type: "road");`)).toContain(
        '`bicycle_type:` need `mode: "bicycle"`'
      );
      expect(messages(`$$ = route(${route}, mode: "auto", use_hills: 0.2);`)).toContain(
        '`use_hills:` need `mode: "bicycle"`, `mode: "foot"`, `mode: "motor_scooter"` or `mode: "transit"`'
      );
      expect(messages(`$$ = route(${route}, mode: "bicycle", wheelchair: true);`)).toContain(
        '`wheelchair:` need `mode: "foot"` or `mode: "transit"`'
      );
      expect(
        messages(
          '$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], mode: "auto", wheelchair: true);'
        )
      ).toContain('`wheelchair:` need `mode: "foot"`');
      expect(messages(`$$ = route(${route}, mode: "foot", use_roads: 0.5);`)).toContain(
        '`use_roads:` need `mode: "bicycle"`'
      );
    });

    it("accepts motorcycle and motor scooter options", () => {
      for (const src of [
        `$$ = route(${route}, mode: "motorcycle", style: "adventure", use_trails: 0.7, use_curves: 0.9, use_tolls: 0, top_speed: 110);`,
        '$$ = isochrone(center: point(40.71, -74.00), time: 600, mode: "motorbike", use_trails: 1);',
        `$$ = route(${route}, mode: "motor_scooter", use_primary: 0.1, use_hills: 0, top_speed: 60);`,
        '$$ = matrix(origins: [point(40.71, -74.00)], destinations: [point(40.75, -73.98)], mode: "moped", use_hills: 0.3);',
      ]) {
        expect(check(src).errors).toHaveLength(0);
      }
    });

    it("checks motorcycle and motor scooter options", () => {
      expect(messages(`$$ = route(${route}, style: "adventure");`)).toContain(
        '`style:` need `mode: "motorcycle"`'
      );
      expect(messages(`$$ = route(${route}, mode: "motorcycle", use_primary: 0.5);`)).toContain(
        '`use_primary:` need `mode: "motor_scooter"`'
      );
      expect(messages(`$$ = route(${route}, mode: "scooter", use_curves: 0.5);`)).toContain(
        '`use_curves:` need `mode: "motorcycle"`'
      );
      expect(messages(`$$ = route(${route}, mode: "motorcycle", style: "sport");`)).toContain(
        '`style:` must be one of "touring", "adventure"'
      );
      expect(messages(`$$ = route(${route}, mode: "motorcycle", use_trails: 2);`)).toContain(
        "`use_trails:` must be a number from 0 to 1"
      );
    });

    it("leaves a mode from a variable to the server", () => {
      expect(check(`$m = "bicycle"; $$ = route(${route}, mode: $m, use_roads: 0.5);`).errors).toHaveLength(0);
    });

    it("rejects them on other computations", () => {
      const result = check(`$$ = nearest(point: point(48.858, 2.294), style: "touring");`);
      expect(
        result.errors.some((e) => e.message.includes("`nearest()` has no bicycle, pedestrian or motorcycle options"))
      ).toBe(true);
    });

    it("takes the motorcycle and motor scooter options on ev_route", () => {
      const ev = "ev_route(origin: point(48.858, 2.294), destination: point(48.87, 2.35), battery: 15000";
      expect(check(`$$ = ${ev}, mode: "motorcycle", style: "touring", lane_splitting: true);`).errors).toHaveLength(0);
      expect(check(`$$ = ${ev}, mode: "scooter", use_primary: 0, use_hills: 0.5);`).errors).toHaveLength(0);
      expect(messages(`$$ = ${ev}, style: "adventure");`)).toContain('`style:` need `mode: "motorcycle"`');
      expect(messages(`$$ = ${ev}, mode: "auto", use_hills: 0.2);`)).toContain(
        '`use_hills:` need `mode: "motor_scooter"`'
      );
      expect(messages(`$$ = ${ev}, mode: "foot", walking_speed: 4);`)).toContain(
        '`ev_route()` has no `walking_speed:`; it takes the motorcycle and motor scooter options, with `mode: "motorcycle"` or `"motor_scooter"`'
      );
    });

    it("checks lane_splitting", () => {
      expect(check(`$$ = route(${route}, mode: "motorcycle", lane_splitting: false);`).errors).toHaveLength(0);
      expect(messages(`$$ = route(${route}, mode: "motorcycle", lane_splitting: "yes");`)).toContain(
        "`lane_splitting:` must be `true` or `false`"
      );
      expect(messages(`$$ = route(${route}, mode: "scooter", lane_splitting: true);`)).toContain(
        '`lane_splitting:` need `mode: "motorcycle"`'
      );
    });

    it("accepts them on optimize, centroid, expansion and map_match", () => {
      const a = "point(48.858, 2.294)";
      const b = "point(48.87, 2.35)";
      for (const src of [
        `$$ = optimize(waypoints: [${a}, ${b}], mode: "motor_scooter", use_primary: 0);`,
        `$$ = centroid(locations: [${a}, ${b}], mode: "motorcycle", style: "adventure");`,
        `$$ = expansion(action: "route", origin: ${a}, destination: ${b}, mode: "foot", walking_speed: 4);`,
        `$$ = map_match(points: [${a}, ${b}], mode: "bicycle", bicycle_type: "road");`,
      ]) {
        expect(check(src).errors).toHaveLength(0);
      }
    });

    it("checks values like the Elixir type checker", () => {
      expect(messages(`$$ = route(${route}, mode: "bicycle", bicycle_type: "tandem");`)).toContain(
        '`bicycle_type:` must be one of "road", "hybrid", "cross", "mountain"'
      );
      expect(messages(`$$ = route(${route}, mode: "bicycle", use_roads: 2);`)).toContain(
        "`use_roads:` must be a number from 0 to 1"
      );
      expect(messages(`$$ = route(${route}, mode: "foot", walking_speed: 20);`)).toContain(
        "`walking_speed:` must be a number from 1 to 10 (km/h)"
      );
      expect(messages(`$$ = route(${route}, mode: "foot", max_hiking_difficulty: 2.5);`)).toContain(
        "`max_hiking_difficulty:` must be a whole number from 1 to 6"
      );
      expect(messages(`$$ = route(${route}, mode: "foot", wheelchair: "yes");`)).toContain(
        "`wheelchair:` must be `true` or `false`"
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
