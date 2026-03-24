import { describe, it, expect } from "vitest";
import { getCompletions } from "../src/completions.js";

describe("PlazaQL Completions", () => {
  // ── A. Tag Key Completions ─────────────────────────────────────────

  describe("Tag key completions inside search()", () => {
    it("suggests tag keys inside search(", () => {
      const items = getCompletions("$$ = search(", 1, 13);
      expect(items.some((i) => i.label === "amenity")).toBe(true);
      expect(items.some((i) => i.label === "highway")).toBe(true);
      expect(items.some((i) => i.label === "building")).toBe(true);
    });

    it("suggests many more than the old 28 keys", () => {
      const items = getCompletions("$$ = search(", 1, 13);
      // Element types + tag keys — should be at least 50 total
      const tagItems = items.filter((i) => i.kind === "tag");
      expect(tagItems.length).toBeGreaterThanOrEqual(50);
    });

    it("tag keys are sorted by rank/popularity", () => {
      const items = getCompletions("$$ = search(", 1, 13);
      const tagItems = items.filter((i) => i.kind === "tag");
      const amenityIdx = tagItems.findIndex((i) => i.label === "amenity");
      const aerowayIdx = tagItems.findIndex((i) => i.label === "aeroway");
      expect(amenityIdx).toBeLessThan(aerowayIdx);
    });

    it("tag keys include descriptions", () => {
      const items = getCompletions("$$ = search(", 1, 13);
      const amenity = items.find((i) => i.label === "amenity");
      expect(amenity?.detail).toBeTruthy();
    });

    it("tag keys include preview of common values in documentation", () => {
      const items = getCompletions("$$ = search(", 1, 13);
      const amenity = items.find((i) => i.label === "amenity");
      expect(amenity?.documentation).toContain("cafe");
    });

    it("tag key insertText appends colon and space", () => {
      const items = getCompletions("$$ = search(", 1, 13);
      const amenity = items.find((i) => i.label === "amenity");
      expect(amenity?.insertText).toBe("amenity: ");
    });

    it("suggests tag keys after comma in search", () => {
      const items = getCompletions('$$ = search(node, amenity: "cafe", ', 1, 35);
      const tagItems = items.filter((i) => i.kind === "tag");
      expect(tagItems.some((i) => i.label === "cuisine")).toBe(true);
      expect(tagItems.some((i) => i.label === "wheelchair")).toBe(true);
    });

    it("suggests tag keys inside .filter(", () => {
      const items = getCompletions('$$ = search(amenity: "cafe").filter(', 1, 36);
      expect(items.some((i) => i.label === "cuisine")).toBe(true);
      expect(items.some((i) => i.label === "wheelchair")).toBe(true);
    });

    it("suggests tag keys after comma in .filter(", () => {
      const items = getCompletions('$$ = search().filter(cuisine: "italian", ', 1, 42);
      const tagItems = items.filter((i) => i.kind === "tag");
      expect(tagItems.some((i) => i.label === "outdoor_seating")).toBe(true);
    });
  });

  // ── B. Tag Value Completions ───────────────────────────────────────

  describe("Tag value completions", () => {
    it("suggests amenity values after amenity: ", () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      expect(items.some((i) => i.label === '"cafe"')).toBe(true);
      expect(items.some((i) => i.label === '"restaurant"')).toBe(true);
      expect(items.some((i) => i.label === '"pharmacy"')).toBe(true);
      expect(items.some((i) => i.label === '"school"')).toBe(true);
    });

    it("suggests shop values after shop: ", () => {
      const items = getCompletions("$$ = search(shop: ", 1, 19);
      expect(items.some((i) => i.label === '"supermarket"')).toBe(true);
      expect(items.some((i) => i.label === '"convenience"')).toBe(true);
      expect(items.some((i) => i.label === '"bakery"')).toBe(true);
    });

    it("suggests highway values after highway: ", () => {
      const items = getCompletions("$$ = search(highway: ", 1, 22);
      expect(items.some((i) => i.label === '"bus_stop"')).toBe(true);
      expect(items.some((i) => i.label === '"cycleway"')).toBe(true);
      expect(items.some((i) => i.label === '"primary"')).toBe(true);
      expect(items.some((i) => i.label === '"residential"')).toBe(true);
    });

    it("suggests tourism values after tourism: ", () => {
      const items = getCompletions("$$ = search(tourism: ", 1, 22);
      expect(items.some((i) => i.label === '"museum"')).toBe(true);
      expect(items.some((i) => i.label === '"viewpoint"')).toBe(true);
      expect(items.some((i) => i.label === '"attraction"')).toBe(true);
    });

    it("suggests leisure values after leisure: ", () => {
      const items = getCompletions("$$ = search(leisure: ", 1, 22);
      expect(items.some((i) => i.label === '"park"')).toBe(true);
      expect(items.some((i) => i.label === '"playground"')).toBe(true);
      expect(items.some((i) => i.label === '"garden"')).toBe(true);
    });

    it("suggests building values after building: ", () => {
      const items = getCompletions("$$ = search(building: ", 1, 23);
      expect(items.some((i) => i.label === '"yes"')).toBe(true);
      expect(items.some((i) => i.label === '"residential"')).toBe(true);
      expect(items.some((i) => i.label === '"apartments"')).toBe(true);
    });

    it("suggests natural values after natural: ", () => {
      const items = getCompletions("$$ = search(natural: ", 1, 22);
      expect(items.some((i) => i.label === '"coastline"')).toBe(true);
      expect(items.some((i) => i.label === '"peak"')).toBe(true);
      expect(items.some((i) => i.label === '"water"')).toBe(true);
      expect(items.some((i) => i.label === '"tree"')).toBe(true);
    });

    it("suggests railway values after railway: ", () => {
      const items = getCompletions("$$ = search(railway: ", 1, 22);
      expect(items.some((i) => i.label === '"station"')).toBe(true);
      expect(items.some((i) => i.label === '"subway_entrance"')).toBe(true);
      expect(items.some((i) => i.label === '"tram_stop"')).toBe(true);
    });

    it("suggests cuisine values after cuisine: ", () => {
      const items = getCompletions("$$ = search(cuisine: ", 1, 22);
      expect(items.some((i) => i.label === '"italian"')).toBe(true);
      expect(items.some((i) => i.label === '"pizza"')).toBe(true);
      expect(items.some((i) => i.label === '"chinese"')).toBe(true);
      expect(items.some((i) => i.label === '"japanese"')).toBe(true);
    });

    it("suggests surface values after surface: ", () => {
      const items = getCompletions("$$ = search(surface: ", 1, 22);
      expect(items.some((i) => i.label === '"asphalt"')).toBe(true);
      expect(items.some((i) => i.label === '"concrete"')).toBe(true);
      expect(items.some((i) => i.label === '"gravel"')).toBe(true);
    });

    it("suggests wheelchair values after wheelchair: ", () => {
      const items = getCompletions("$$ = search(wheelchair: ", 1, 25);
      expect(items.some((i) => i.label === '"yes"')).toBe(true);
      expect(items.some((i) => i.label === '"no"')).toBe(true);
      expect(items.some((i) => i.label === '"limited"')).toBe(true);
    });

    it("suggests boolean values after outdoor_seating: ", () => {
      const items = getCompletions("$$ = search(outdoor_seating: ", 1, 30);
      expect(items.some((i) => i.label === '"yes"')).toBe(true);
      expect(items.some((i) => i.label === '"no"')).toBe(true);
    });

    it("returns only filter operators for freeform keys like name: ", () => {
      const items = getCompletions("$$ = search(name: ", 1, 19);
      const valueItems = items.filter((i) => i.kind === "value");
      expect(valueItems.length).toBe(0);
      const operatorItems = items.filter((i) => i.kind === "operator");
      expect(operatorItems.length).toBeGreaterThan(0);
    });

    it("returns only filter operators for unknown keys", () => {
      const items = getCompletions("$$ = search(unknown_tag: ", 1, 26);
      const valueItems = items.filter((i) => i.kind === "value");
      expect(valueItems.length).toBe(0);
      const operatorItems = items.filter((i) => i.kind === "operator");
      expect(operatorItems.length).toBeGreaterThan(0);
    });

    it("always includes filter operators alongside values", () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      expect(items.some((i) => i.label === "*")).toBe(true);
      expect(items.some((i) => i.label === "!*")).toBe(true);
      expect(items.some((i) => i.kind === "value")).toBe(true);
    });

    it("values sort before operators", () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      const values = items.filter((i) => i.kind === "value");
      const operators = items.filter((i) => i.kind === "operator");
      expect(values[0]!.sortText! < operators[0]!.sortText!).toBe(true);
    });

    it('value insertText includes quotes', () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      const cafe = items.find((i) => i.label === '"cafe"');
      expect(cafe?.insertText).toBe('"cafe"');
    });

    it("suggests values inside .filter() after tag key", () => {
      const items = getCompletions('$$ = search().filter(amenity: ', 1, 30);
      expect(items.some((i) => i.label === '"cafe"')).toBe(true);
      expect(items.some((i) => i.label === '"restaurant"')).toBe(true);
    });
  });

  // ── C. Filter Operator Completions ─────────────────────────────────

  describe("Filter operator completions", () => {
    it("includes exists operator *", () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      expect(items.some((i) => i.label === "*")).toBe(true);
    });

    it("includes not-exists operator !*", () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      expect(items.some((i) => i.label === "!*")).toBe(true);
    });

    it('includes regex operator ~"…"', () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      expect(items.some((i) => i.label === '~"…"')).toBe(true);
    });

    it('includes case-insensitive regex ~i"…"', () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      expect(items.some((i) => i.label === '~i"…"')).toBe(true);
    });

    it('includes negated regex !~"…"', () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      expect(items.some((i) => i.label === '!~"…"')).toBe(true);
    });

    it('includes not-equal !"…"', () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      expect(items.some((i) => i.label === '!"…"')).toBe(true);
    });

    it("each operator has descriptive detail text", () => {
      const items = getCompletions("$$ = search(amenity: ", 1, 22);
      const ops = items.filter((i) => i.kind === "operator");
      for (const op of ops) {
        expect(op.detail, `operator ${op.label} missing detail`).toBeTruthy();
      }
    });
  });

  // ── D. Element Type Completions ────────────────────────────────────

  describe("Element type completions in search()", () => {
    it("suggests node, way, relation, nwr at first position", () => {
      const items = getCompletions("$$ = search(", 1, 13);
      expect(items.some((i) => i.label === "node")).toBe(true);
      expect(items.some((i) => i.label === "way")).toBe(true);
      expect(items.some((i) => i.label === "relation")).toBe(true);
      expect(items.some((i) => i.label === "nwr")).toBe(true);
    });

    it("element types include descriptions", () => {
      const items = getCompletions("$$ = search(", 1, 13);
      const node = items.find((i) => i.label === "node");
      expect(node?.detail).toContain("Node");
    });

    it("also suggests tag keys at first position", () => {
      const items = getCompletions("$$ = search(", 1, 13);
      expect(items.some((i) => i.label === "amenity")).toBe(true);
    });

    it("does NOT suggest element types after comma", () => {
      const items = getCompletions("$$ = search(node, ", 1, 19);
      expect(items.some((i) => i.label === "way")).toBe(false);
      expect(items.some((i) => i.label === "relation")).toBe(false);
    });

    it("does NOT suggest element types inside .filter()", () => {
      const items = getCompletions('$$ = search().filter(', 1, 22);
      expect(items.some((i) => i.label === "node")).toBe(false);
      expect(items.some((i) => i.label === "way")).toBe(false);
    });
  });

  // ── E. Type-Aware Dot Completions ──────────────────────────────────

  describe("Type-aware dot completions", () => {
    it("suggests methods for GeoSet after search()", () => {
      const items = getCompletions('$$ = search(amenity: "cafe").', 1, 29);
      expect(items.length).toBeGreaterThan(0);
      expect(items.some((i) => i.label === "within")).toBe(true);
      expect(items.some((i) => i.label === "around")).toBe(true);
      expect(items.some((i) => i.label === "limit")).toBe(true);
      expect(items.some((i) => i.label === "count")).toBe(true);
    });

    it("suggests methods for PointSet after search(node, ...)", () => {
      const items = getCompletions('$$ = search(node, amenity: "cafe").', 1, 35);
      expect(items.length).toBeGreaterThan(0);
      expect(items.some((i) => i.label === "within")).toBe(true);
    });

    it("returns NO methods after .count()", () => {
      const items = getCompletions("$$ = search().count().", 1, 22);
      expect(items.length).toBe(0);
    });

    it("returns NO methods after .ids()", () => {
      const items = getCompletions("$$ = search().ids().", 1, 20);
      expect(items.length).toBe(0);
    });

    it("returns NO methods after .tags()", () => {
      const items = getCompletions("$$ = search().tags().", 1, 21);
      expect(items.length).toBe(0);
    });

    it("returns NO methods after .skel()", () => {
      const items = getCompletions("$$ = search().skel().", 1, 21);
      expect(items.length).toBe(0);
    });

    it("excludes freely_orderable methods after late_chain method", () => {
      const items = getCompletions("$$ = search().limit(10).", 1, 24);
      const labels = items.map((i) => i.label);
      expect(labels).not.toContain("within");
      expect(labels).not.toContain("around");
      expect(labels).not.toContain("buffer");
      expect(labels).not.toContain("filter");
      // Should still include terminal + other late_chain
      expect(labels).toContain("count");
      expect(labels).toContain("offset");
    });

    it("infers PointSet after .centroid()", () => {
      const items = getCompletions('$$ = search(building: *).centroid().', 1, 36);
      // Should have methods — PointSet is chainable
      expect(items.length).toBeGreaterThan(0);
    });

    it("infers PolygonSet after .buffer()", () => {
      const items = getCompletions('$$ = search(node, amenity: "cafe").buffer(50).', 1, 47);
      expect(items.length).toBeGreaterThan(0);
    });

    it("auto-closes parens for no-arg methods", () => {
      const items = getCompletions("$$ = search().", 1, 15);
      const centroid = items.find((i) => i.label === "centroid");
      expect(centroid?.insertText).toBe("centroid()");
      const count = items.find((i) => i.label === "count");
      expect(count?.insertText).toBe("count()");
    });

    it("opens parens for methods with args", () => {
      const items = getCompletions("$$ = search().", 1, 15);
      const within = items.find((i) => i.label === "within");
      expect(within?.insertText).toBe("within(");
      const around = items.find((i) => i.label === "around");
      expect(around?.insertText).toBe("around(");
    });

    it("terminal methods sort last", () => {
      const items = getCompletions("$$ = search().", 1, 15);
      const count = items.find((i) => i.label === "count");
      expect(count?.sortText).toMatch(/^z/);
    });

    it("late_chain methods sort after freely_orderable", () => {
      const items = getCompletions("$$ = search().", 1, 15);
      const limit = items.find((i) => i.label === "limit");
      expect(limit?.sortText).toMatch(/^y/);
    });

    it("freely_orderable methods sort first", () => {
      const items = getCompletions("$$ = search().", 1, 15);
      const within = items.find((i) => i.label === "within");
      expect(within?.sortText).toMatch(/^a/);
    });
  });

  // ── F. Method Parameter Value Completions ──────────────────────────

  describe("Method parameter value completions", () => {
    it("suggests mode values for route(mode: )", () => {
      const items = getCompletions("$$ = route(origin: point(0,0), destination: point(1,1), mode: ", 1, 63);
      expect(items.some((i) => i.label === '"auto"')).toBe(true);
      expect(items.some((i) => i.label === '"foot"')).toBe(true);
      expect(items.some((i) => i.label === '"bicycle"')).toBe(true);
    });

    it("suggests mode values for isochrone(mode: )", () => {
      const items = getCompletions("$$ = isochrone(center: point(0,0), time: 600, mode: ", 1, 53);
      expect(items.some((i) => i.label === '"auto"')).toBe(true);
      expect(items.some((i) => i.label === '"foot"')).toBe(true);
    });

    it("suggests expression functions for .sort(by: )", () => {
      const items = getCompletions("$$ = search().sort(by: ", 1, 24);
      expect(items.some((i) => i.label === 't["')).toBe(true);
      expect(items.some((i) => i.label === "distance(")).toBe(true);
      expect(items.some((i) => i.label === "area()")).toBe(true);
      expect(items.some((i) => i.label === "length()")).toBe(true);
      expect(items.some((i) => i.label === "elevation()")).toBe(true);
      expect(items.some((i) => i.label === "number(")).toBe(true);
      expect(items.some((i) => i.label === "id()")).toBe(true);
    });

    it("suggests expression functions for .sort(", () => {
      const items = getCompletions("$$ = search().sort(", 1, 20);
      expect(items.some((i) => i.label === 't["')).toBe(true);
      expect(items.some((i) => i.label === "distance(")).toBe(true);
      expect(items.some((i) => i.label === "area()")).toBe(true);
      expect(items.some((i) => i.label === "elevation()")).toBe(true);
      expect(items.some((i) => i.label === "id()")).toBe(true);
    });

    it("suggests by: and order: params for .sort(", () => {
      const items = getCompletions("$$ = search().sort(", 1, 20);
      expect(items.some((i) => i.label === "by" && i.kind === "param")).toBe(true);
      expect(items.some((i) => i.label === "order" && i.kind === "param")).toBe(true);
    });

    it("suggests :asc and :desc for .sort(..., order: )", () => {
      const items = getCompletions("$$ = search().sort(distance(), order: ", 1, 38);
      expect(items.some((i) => i.label === ":asc")).toBe(true);
      expect(items.some((i) => i.label === ":desc")).toBe(true);
    });

    it("does not suggest old atom sort values", () => {
      const items = getCompletions("$$ = search().sort(", 1, 20);
      expect(items.some((i) => i.label === ":distance")).toBe(false);
      expect(items.some((i) => i.label === ":name")).toBe(false);
      expect(items.some((i) => i.label === ":osm_id")).toBe(false);
    });

    it("suggests expand direction values for .expand(direction: )", () => {
      const items = getCompletions("$$ = search().expand(direction: ", 1, 32);
      expect(items.some((i) => i.label === ":down")).toBe(true);
      expect(items.some((i) => i.label === ":up")).toBe(true);
    });

    it("falls back to param names when not after a specific param", () => {
      const items = getCompletions("$$ = route(", 1, 12);
      expect(items.some((i) => i.label === "origin")).toBe(true);
      expect(items.some((i) => i.label === "destination")).toBe(true);
      expect(items.some((i) => i.label === "mode")).toBe(true);
    });

    it("suggests param names for isochrone(", () => {
      const items = getCompletions("$$ = isochrone(", 1, 16);
      expect(items.some((i) => i.label === "center")).toBe(true);
      expect(items.some((i) => i.label === "time")).toBe(true);
    });

    it("suggests param names for geocode(", () => {
      const items = getCompletions("$$ = geocode(", 1, 14);
      expect(items.some((i) => i.label === "query")).toBe(true);
    });
  });

  // ── G. Top-Level Completions ───────────────────────────────────────

  describe("Top-level completions", () => {
    it("includes all global functions", () => {
      const items = getCompletions("", 1, 1);
      const labels = items.map((i) => i.label);
      expect(labels).toContain("search");
      expect(labels).toContain("boundary");
      expect(labels).toContain("route");
      expect(labels).toContain("isochrone");
      expect(labels).toContain("geocode");
      expect(labels).toContain("reverse_geocode");
      expect(labels).toContain("text_search");
      expect(labels).toContain("point");
      expect(labels).toContain("bbox");
      expect(labels).toContain("linestring");
      expect(labels).toContain("polygon");
    });

    it("includes variable and output assignment", () => {
      const items = getCompletions("", 1, 1);
      const labels = items.map((i) => i.label);
      expect(labels).toContain("$");
      expect(labels).toContain("$$");
      expect(labels).toContain("[");
    });

    it("function completions show return type", () => {
      const items = getCompletions("", 1, 1);
      const search = items.find((i) => i.label === "search");
      expect(search?.detail).toContain("GeoSet");
      const route = items.find((i) => i.label === "route");
      expect(route?.detail).toContain("Route");
    });

    it("function insertText opens paren", () => {
      const items = getCompletions("", 1, 1);
      const search = items.find((i) => i.label === "search");
      expect(search?.insertText).toBe("search(");
      const route = items.find((i) => i.label === "route");
      expect(route?.insertText).toBe("route(");
    });
  });

  // ── H. Variable & Output Completions ──────────────────────────────

  describe("Variable completions", () => {
    it("suggests defined variables after $", () => {
      const source = '$berlin = boundary(name: "Berlin");\n$$ = $';
      const items = getCompletions(source, 2, 7);
      expect(items.some((i) => i.label === "$berlin")).toBe(true);
    });

    it("includes type info in detail", () => {
      const source = '$berlin = boundary(name: "Berlin");\n$$ = $';
      const items = getCompletions(source, 2, 7);
      const berlin = items.find((i) => i.label === "$berlin");
      expect(berlin?.detail).toContain("Boundary");
    });

    it("includes definition line in documentation", () => {
      const source = '$p = point(38.9, -77.0);\n$$ = $';
      const items = getCompletions(source, 2, 7);
      const p = items.find((i) => i.label === "$p");
      expect(p?.documentation).toContain("line");
    });

    it("strips $ from insertText", () => {
      const source = '$p = point(38.9, -77.0);\n$$ = $';
      const items = getCompletions(source, 2, 7);
      const p = items.find((i) => i.label === "$p");
      expect(p?.insertText).toBe("p");
    });
  });

  describe("Output reference completions", () => {
    it("suggests named outputs after $$. in value position", () => {
      const source = '$$.cafes = search(amenity: "cafe");\n$$ = search().within(geometry: $$.';
      const items = getCompletions(source, 2, 35);
      expect(items.some((i) => i.label === "cafes")).toBe(true);
    });

    it("does not suggest output refs at statement start", () => {
      const items = getCompletions("$$.", 1, 4);
      // At statement start, $$.  → after_out context, not dollar_dollar
      expect(items.some((i) => i.label === "= ")).toBe(true);
    });
  });

  // ── I. Edge Cases & Regression ─────────────────────────────────────

  describe("Edge cases", () => {
    it("handles empty source", () => {
      const items = getCompletions("", 1, 1);
      expect(items.length).toBeGreaterThan(0);
    });

    it("handles cursor at very start of file", () => {
      const items = getCompletions("search", 1, 1);
      expect(items.length).toBeGreaterThanOrEqual(0);
    });

    it("handles partial method names after dot", () => {
      const items = getCompletions("$$ = search().wi", 1, 17);
      // Should be "dot" context — partial method name
      expect(items.some((i) => i.label === "within")).toBe(true);
    });

    it("handles nested function calls", () => {
      const items = getCompletions("$$ = search().around(500, point(", 1, 33);
      // Should be inside point() params, not search() params
      expect(items.some((i) => i.label === "lat")).toBe(true);
    });

    it("handles multiline queries", () => {
      const source = '$$ = search(amenity: "cafe")\n  .within(geometry: point(0,0))\n  .';
      const items = getCompletions(source, 3, 4);
      expect(items.length).toBeGreaterThan(0);
      expect(items.some((i) => i.kind === "method")).toBe(true);
    });

    it("after $$ suggests = and .name", () => {
      const items = getCompletions("$$", 1, 3);
      expect(items.length).toBeGreaterThan(0);
    });

    it("variable completions include type info", () => {
      const source = '$p = point(38.9, -77.0);\n$$ = $';
      const items = getCompletions(source, 2, 7);
      const pVar = items.find((i) => i.label === "$p");
      expect(pVar).toBeDefined();
      expect(pVar?.detail).toContain("Point");
    });

    it("method completions include category info", () => {
      const items = getCompletions("$$ = search().", 1, 15);
      const within = items.find((i) => i.label === "within");
      expect(within).toBeDefined();
      expect(within?.detail).toContain("Spatial");
    });

    it("returns completions for empty source", () => {
      const items = getCompletions("", 1, 1);
      expect(items.length).toBeGreaterThan(0);
    });
  });
});
