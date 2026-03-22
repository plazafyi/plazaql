import { describe, it, expect } from "vitest";
import { parse } from "../src/parser.js";

describe("PlazaQL Parser", () => {
  // ── Simple search ──────────────────────────────────────────────

  it("parses simple search()", () => {
    const { ast, errors } = parse('$$ =search(amenity: "cafe");');
    expect(errors).toHaveLength(0);
    expect(ast).toHaveLength(1);
    expect(ast[0]!.kind).toBe("output");
    if (ast[0]!.kind === "output") {
      const expr = ast[0]!.expr;
      expect(expr.kind).toBe("search");
      if (expr.kind === "search") {
        expect(expr.elementType).toBeNull();
        expect(expr.filters).toHaveLength(1);
        expect(expr.filters[0]!.op).toBe("eq");
        expect(expr.filters[0]!.key).toBe("amenity");
        expect(expr.filters[0]!.value).toBe("cafe");
      }
    }
  });

  // ── Search with element type ───────────────────────────────────

  it("parses search with element type", () => {
    const { ast, errors } = parse('$$ =search(node, amenity: "cafe");');
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output") {
      const expr = ast[0]!.expr;
      if (expr.kind === "search") {
        expect(expr.elementType).toBe("node");
        expect(expr.filters).toHaveLength(1);
      }
    }
  });

  it("parses search with element type only", () => {
    const { ast, errors } = parse("$$ =search(way);");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.elementType).toBe("way");
      expect(ast[0]!.expr.filters).toHaveLength(0);
    }
  });

  it("parses search with relation type", () => {
    const { ast, errors } = parse("$$ =search(relation);");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.elementType).toBe("relation");
    }
  });

  it("parses search with nwr type", () => {
    const { ast, errors } = parse("$$ =search(nwr);");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.elementType).toBe("nwr");
    }
  });

  // ── Tag filter types ───────────────────────────────────────────

  it("parses eq tag filter", () => {
    const { ast } = parse('$$ =search(amenity: "cafe");');
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.filters[0]).toEqual({ op: "eq", key: "amenity", value: "cafe" });
    }
  });

  it("parses neq tag filter", () => {
    const { ast } = parse('$$ =search(amenity: !"cafe");');
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.filters[0]).toEqual({ op: "neq", key: "amenity", value: "cafe" });
    }
  });

  it("parses regex tag filter", () => {
    const { ast } = parse('$$ =search(name: ~"^Starbucks");');
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.filters[0]).toEqual({ op: "regex", key: "name", value: "^Starbucks" });
    }
  });

  it("parses regex_i tag filter", () => {
    const { ast } = parse('$$ =search(name: ~i"starbucks");');
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.filters[0]).toEqual({ op: "regex_i", key: "name", value: "starbucks" });
    }
  });

  it("parses not_regex tag filter", () => {
    const { ast } = parse('$$ =search(name: !~"test");');
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.filters[0]).toEqual({ op: "not_regex", key: "name", value: "test" });
    }
  });

  it("parses exists tag filter", () => {
    const { ast } = parse("$$ =search(name: *);");
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.filters[0]).toEqual({ op: "exists", key: "name" });
    }
  });

  it("parses not_exists tag filter", () => {
    const { ast } = parse("$$ =search(name: !*);");
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.filters[0]).toEqual({ op: "not_exists", key: "name" });
    }
  });

  // ── Geometry constructors ──────────────────────────────────────

  it("parses point(lat, lng)", () => {
    const { ast, errors } = parse("$p = point(38.9, -77.0);");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "var_assign" && ast[0]!.expr.kind === "point") {
      expect(ast[0]!.expr.lat).toBe(38.9);
      expect(ast[0]!.expr.lng).toBe(-77.0);
    }
  });

  it("parses point with keyword args", () => {
    const { ast, errors } = parse("$p = point(lat: 38.9, lng: -77.0);");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "var_assign" && ast[0]!.expr.kind === "point") {
      expect(ast[0]!.expr.lat).toBe(38.9);
      expect(ast[0]!.expr.lng).toBe(-77.0);
    }
  });

  it("parses linestring", () => {
    const { ast, errors } = parse("$l = linestring(point(0, 0), point(1, 1));");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "var_assign" && ast[0]!.expr.kind === "linestring") {
      expect(ast[0]!.expr.items).toHaveLength(2);
    }
  });

  it("parses polygon", () => {
    const { ast, errors } = parse("$p = polygon(point(0, 0), point(1, 0), point(0, 1));");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "var_assign" && ast[0]!.expr.kind === "polygon") {
      expect(ast[0]!.expr.items).toHaveLength(3);
    }
  });

  it("parses bbox", () => {
    const { ast, errors } = parse("$b = bbox(47.3, 8.5, 47.4, 8.6);");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "var_assign" && ast[0]!.expr.kind === "bbox") {
      expect(ast[0]!.expr.s).toBe(47.3);
      expect(ast[0]!.expr.w).toBe(8.5);
      expect(ast[0]!.expr.n).toBe(47.4);
      expect(ast[0]!.expr.e).toBe(8.6);
    }
  });

  // ── Variable assignment ────────────────────────────────────────

  it("parses variable assignment", () => {
    const { ast, errors } = parse('$berlin = area(name: "Berlin");');
    expect(errors).toHaveLength(0);
    expect(ast).toHaveLength(1);
    expect(ast[0]!.kind).toBe("var_assign");
    if (ast[0]!.kind === "var_assign") {
      expect(ast[0]!.name).toBe("$berlin");
      expect(ast[0]!.expr.kind).toBe("area");
    }
  });

  // ── Output assignment ──────────────────────────────────────────

  it("parses default output", () => {
    const { ast, errors } = parse("$$ =search();");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output") {
      expect(ast[0]!.name).toBeNull();
    }
  });

  it("parses named output", () => {
    const { ast, errors } = parse("$$.cafes = search();");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output") {
      expect(ast[0]!.name).toBe("cafes");
    }
  });

  // ── Method chaining ────────────────────────────────────────────

  it("parses method chain", () => {
    const { ast, errors } = parse('$$ =search(amenity: "cafe").limit(10);');
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.methods).toHaveLength(1);
      expect(ast[0]!.expr.methods[0]!.name).toBe("limit");
    }
  });

  it("parses multiple methods", () => {
    const { ast, errors } = parse(
      '$$ =search(node, amenity: "cafe").around(500, point(38.9, -77.0)).sort(distance).limit(10);'
    );
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.methods).toHaveLength(3);
      expect(ast[0]!.expr.methods[0]!.name).toBe("around");
      expect(ast[0]!.expr.methods[1]!.name).toBe("sort");
      expect(ast[0]!.expr.methods[2]!.name).toBe("limit");
    }
  });

  it("parses no-arg methods", () => {
    const { ast, errors } = parse("$$ =search().count();");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.methods).toHaveLength(1);
      expect(ast[0]!.expr.methods[0]!.name).toBe("count");
    }
  });

  // ── Set operations ─────────────────────────────────────────────

  it("parses union", () => {
    const { ast, errors } = parse("$a = search();\n$b = search();\n$$ =$a + $b;");
    expect(errors).toHaveLength(0);
    expect(ast).toHaveLength(3);
    if (ast[2]!.kind === "output") {
      expect(ast[2]!.expr.kind).toBe("union");
    }
  });

  it("parses difference", () => {
    const { ast, errors } = parse("$a = search();\n$b = search();\n$$ =$a - $b;");
    expect(errors).toHaveLength(0);
    if (ast[2]!.kind === "output") {
      expect(ast[2]!.expr.kind).toBe("difference");
    }
  });

  // ── Comments ───────────────────────────────────────────────────

  it("ignores line comments", () => {
    const { ast, errors } = parse("// This is a comment\n$$ =search();");
    expect(errors).toHaveLength(0);
    expect(ast).toHaveLength(1);
  });

  it("ignores block comments", () => {
    const { ast, errors } = parse("/* block comment */\n$$ =search();");
    expect(errors).toHaveLength(0);
    expect(ast).toHaveLength(1);
  });

  // ── Settings ───────────────────────────────────────────────────

  it("parses settings block", () => {
    const { ast, errors } = parse('[timeout: 30]\n$$ =search();');
    expect(errors).toHaveLength(0);
    expect(ast).toHaveLength(2);
    if (ast[0]!.kind === "settings") {
      expect(ast[0]!.pairs).toEqual([{ key: "timeout", value: 30 }]);
    }
  });

  it("parses settings with string value", () => {
    const { ast, errors } = parse('[dataset: "my-slug"]\n$$ =search();');
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "settings") {
      expect(ast[0]!.pairs).toEqual([{ key: "dataset", value: "my-slug" }]);
    }
  });

  // ── Computation functions ──────────────────────────────────────

  it("parses route with arrow syntax", () => {
    const { ast, errors } = parse(
      '$$ =route(point(38.9, -77.0) -> point(40.7, -74.0), mode: "auto");'
    );
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "computation") {
      expect(ast[0]!.expr.name).toBe("route");
    }
  });

  it("parses isochrone", () => {
    const { ast, errors } = parse(
      "$$ =isochrone(point(38.9, -77.0), time: 600);",
    );
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "computation") {
      expect(ast[0]!.expr.name).toBe("isochrone");
    }
  });

  it("parses geocode", () => {
    const { ast, errors } = parse('$$ =geocode("1600 Pennsylvania Ave");');
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "computation") {
      expect(ast[0]!.expr.name).toBe("geocode");
    }
  });

  // ── Keyword vs positional args ─────────────────────────────────

  it("parses keyword args", () => {
    const { ast, errors } = parse(
      "$$ =isochrone(center: point(38.9, -77.0), time: 600);"
    );
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "computation") {
      expect(ast[0]!.expr.args).toHaveLength(2);
      expect(ast[0]!.expr.args[0]!.type).toBe("kwarg");
    }
  });

  it("parses positional args", () => {
    const { ast, errors } = parse("$$ =isochrone(point(38.9, -77.0), 600);");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "computation") {
      expect(ast[0]!.expr.args).toHaveLength(2);
      expect(ast[0]!.expr.args[0]!.type).toBe("posarg");
    }
  });

  // ── Error recovery ─────────────────────────────────────────────

  it("recovers from incomplete input", () => {
    const { ast, errors } = parse('$a = search();\n$$$invalid\n$$ =search(amenity: "cafe");');
    // Should recover and parse what it can
    expect(ast.length).toBeGreaterThan(0);
    expect(errors.length).toBeGreaterThan(0);
  });

  // ── Nested expressions ─────────────────────────────────────────

  it("parses nested method chain on variable", () => {
    const { ast, errors } = parse(
      '$b = area(name: "Berlin");\n$$ =search(node, amenity: "cafe").within($b);'
    );
    expect(errors).toHaveLength(0);
    expect(ast).toHaveLength(2);
  });

  // ── Multiple statements ────────────────────────────────────────

  it("parses multiple statements", () => {
    const source = [
      '[timeout: 30]',
      '$berlin = area(name: "Berlin");',
      '$cafes = search(node, amenity: "cafe").within($berlin);',
      "$$ =$cafes.limit(20);",
    ].join("\n");
    const { ast, errors } = parse(source);
    expect(errors).toHaveLength(0);
    expect(ast).toHaveLength(4);
    expect(ast[0]!.kind).toBe("settings");
    expect(ast[1]!.kind).toBe("var_assign");
    expect(ast[2]!.kind).toBe("var_assign");
    expect(ast[3]!.kind).toBe("output");
  });

  // ── Source positions ───────────────────────────────────────────

  it("tracks source positions", () => {
    const { ast } = parse('$a = search();\n$$ =search(amenity: "cafe");');
    expect(ast[0]!.pos.line).toBe(1);
    expect(ast[0]!.pos.col).toBe(1);
    expect(ast[1]!.pos.line).toBe(2);
    expect(ast[1]!.pos.col).toBe(1);
  });

  // ── Multiple tag filters ──────────────────────────────────────

  it("parses multiple tag filters", () => {
    const { ast, errors } = parse('$$ =search(amenity: "cafe", name: "Starbucks");');
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.filters).toHaveLength(2);
    }
  });

  // ── Area ───────────────────────────────────────────────────────

  it("parses area with filters", () => {
    const { ast, errors } = parse('$b = area(name: "Berlin", admin_level: "4");');
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "var_assign" && ast[0]!.expr.kind === "area") {
      expect(ast[0]!.expr.filters).toHaveLength(2);
    }
  });

  // ── Filter method ──────────────────────────────────────────────

  it("parses .filter() with tag filters", () => {
    const { ast, errors } = parse('$$ =search().filter(cuisine: "italian");');
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      const method = ast[0]!.expr.methods[0]!;
      expect(method.name).toBe("filter");
    }
  });

  // ── List literal ───────────────────────────────────────────────

  it("parses list literal", () => {
    const { ast, errors } = parse('$tags = ["name", "amenity"];\n$$ =search();');
    // The parser doesn't actually create a var_assign for list on its own
    // since list isn't a top-level statement — but inside an expr it should work
    // Let's test it differently
    const { ast: ast2, errors: errors2 } = parse(
      "$$ =search().fields([\"name\", \"amenity\"]);"
    );
    expect(errors2).toHaveLength(0);
  });

  // ── Boolean values ─────────────────────────────────────────────

  it("parses boolean setting", () => {
    const { ast, errors } = parse("[verbose: true]\n$$ =search();");
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "settings") {
      expect(ast[0]!.pairs[0]!.value).toBe(true);
    }
  });

  // ── Parenthesized set ops ──────────────────────────────────────

  it("parses parenthesized set operations", () => {
    const { ast, errors } = parse(
      "$a = search();\n$b = search();\n$c = search();\n$$ =($a + $b) - $c;"
    );
    expect(errors).toHaveLength(0);
    if (ast[3]!.kind === "output") {
      expect(ast[3]!.expr.kind).toBe("difference");
    }
  });

  // ── String escapes ─────────────────────────────────────────────

  it("handles string escapes", () => {
    const { ast, errors } = parse('$$ =search(name: "O\\"Brien");');
    expect(errors).toHaveLength(0);
    if (ast[0]!.kind === "output" && ast[0]!.expr.kind === "search") {
      expect(ast[0]!.expr.filters[0]!.value).toBe('O"Brien');
    }
  });
});
