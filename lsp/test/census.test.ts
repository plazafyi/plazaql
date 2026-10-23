import { describe, expect, it } from "vitest";
import { getCompletions } from "../src/completions.js";
import { formatDocument } from "../src/formatter.js";
import { getHover } from "../src/hover.js";
import { parse } from "../src/parser.js";
import { getSignatureHelp } from "../src/signatures.js";
import { typeCheck } from "../src/type-checker.js";
import type { Expr, MethodNode, SearchNode } from "../src/types.js";

const ISO =
  '$area = isochrone(center: point(40.7484, -73.9856), time: 900, mode: "foot");\n';

function check(source: string) {
  const { ast, errors } = parse(source);
  expect(errors).toHaveLength(0);
  return typeCheck(ast);
}

function lastSearchMethods(source: string): MethodNode[] {
  const { ast } = parse(source);
  const last = ast[ast.length - 1];
  if (!last || last.kind === "settings") {
    throw new Error("no expression statement");
  }
  return (last.expr as SearchNode).methods;
}

function firstArg(method: MethodNode | undefined): Expr {
  const arg = method?.args[0];
  if (!arg || !("type" in arg)) {
    throw new Error("expected a regular argument");
  }
  return arg.value;
}

describe("overlap_fraction — parser", () => {
  it("parses the expression form inside .sum() as an opaque expression with calls", () => {
    const [sum] = lastSearchMethods(
      `${ISO}search(dataset("census-tracts")).sum(number(t["population"]) * overlap_fraction($area));`,
    );
    expect(sum?.name).toBe("sum");
    const expr = firstArg(sum);
    expect(expr.kind).toBe("expression");
    if (expr.kind !== "expression") return;
    expect(expr.text).toBe('number(t["population"]) * overlap_fraction($area)');
    expect(expr.calls).toHaveLength(1);
    expect(expr.calls[0]?.arg).toMatchObject({ kind: "var_ref", name: "$area" });
  });

  it("parses a standalone overlap_fraction() argument", () => {
    const [sort] = lastSearchMethods(
      "search(node).sort(overlap_fraction(bbox(40.70, -74.02, 40.75, -73.97)));",
    );
    const expr = firstArg(sort);
    expect(expr.kind).toBe("overlap_fraction");
    if (expr.kind !== "overlap_fraction") return;
    expect(expr.arg).toMatchObject({ kind: "bbox", s: 40.7, w: -74.02, n: 40.75, e: -73.97 });
  });

  it("parses the keyword-argument form (.sort(by: overlap_fraction(...)))", () => {
    const [sort] = lastSearchMethods("search(node).sort(by: overlap_fraction($$.zone), order: :desc);");
    expect(sort?.args[0]).toMatchObject({
      type: "kwarg",
      name: "by",
      value: { kind: "overlap_fraction", arg: { kind: "output_ref", name: "zone" } },
    });
  });

  it("parses the .overlap_fraction() method", () => {
    const [method] = lastSearchMethods("search(node).overlap_fraction($$.zone);");
    expect(method?.name).toBe("overlap_fraction");
    expect(method?.args).toEqual([
      { type: "posarg", value: { kind: "output_ref", name: "zone", pos: { line: 1, col: 31 } } },
    ]);
  });

  it("does not include the method name in method args", () => {
    const [limit] = lastSearchMethods("search(node).limit(10);");
    expect(limit?.args).toHaveLength(1);
    expect(firstArg(limit)).toMatchObject({ kind: "number", value: 10 });
  });
});

describe("overlap_fraction — type checker", () => {
  it.each([
    '.sum(number(t["population"]) * overlap_fraction($area))',
    ".filter(overlap_fraction($area) > 0.5)",
    ".sort(overlap_fraction($area), order: :desc)",
    ".avg(overlap_fraction(bbox(40.70, -74.02, 40.75, -73.97)))",
    ".max(overlap_fraction(polygon(point(1, 2), point(3, 4), point(5, 6))))",
    ".overlap_fraction($area)",
  ])("accepts %s", (method) => {
    const result = check(`${ISO}search(dataset("census-tracts")).intersects($area)${method};`);
    expect(result.errors).toHaveLength(0);
  });

  it("reports an undefined variable inside an expression", () => {
    const result = check("search(node).sum(number(t[\"pop\"]) * overlap_fraction($nope));");
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]?.message).toBe("undefined variable `$nope`");
  });

  it("reports an undefined variable in the method form once", () => {
    const result = check("search(node).overlap_fraction($nope);");
    expect(result.errors.map((e) => e.message)).toEqual(["undefined variable `$nope`"]);
  });

  it("rejects a point argument with a hint", () => {
    const result = check("search(node).filter(overlap_fraction(point(1, 2)) > 0);");
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]?.message).toContain(
      "expects a polygon(...), bbox(...), or a variable holding polygons",
    );
    expect(result.errors[0]?.hint).toContain("bbox(s, w, n, e)");
  });

  it("rejects a variable that cannot hold polygons", () => {
    const result = check("$p = point(1, 2);\nsearch(node).overlap_fraction($p);");
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]?.message).toContain("but `$p` is Point");
  });
});

describe("variable geometry in spatial predicates", () => {
  it("accepts $var and $$.name in .within/.intersects", () => {
    expect(check(`${ISO}search(dataset("census-tracts")).intersects($area);`).errors).toHaveLength(0);
    expect(
      check(
        '$$.zone = isochrone(center: point(40.7, -73.9), time: 600);\n$$.cafes = search(node, amenity: "cafe").within($$.zone);',
      ).errors,
    ).toHaveLength(0);
  });

  it("accepts bbox in .intersects", () => {
    expect(check("search(node).intersects(bbox(40.70, -74.02, 40.75, -73.97));").errors).toHaveLength(0);
  });
});

describe("reverse_geocode include:", () => {
  it("accepts include: \"census\" and [\"census\"]", () => {
    expect(check('reverse_geocode(point(40.7484, -73.9856), include: "census");').errors).toHaveLength(0);
    expect(check('reverse_geocode(point(40.7484, -73.9856), include: ["census"]);').errors).toHaveLength(0);
  });

  it("rejects unknown include values with a hint", () => {
    const result = check('reverse_geocode(point(1, 2), include: "zip");');
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]?.message).toContain('unknown `include:` value "zip"');
    expect(result.errors[0]?.hint).toBe('supported values: "census"');
  });

  it("completes include: values", () => {
    const src = "reverse_geocode(point(1, 2), include: ";
    const labels = getCompletions(src, 1, src.length + 1).map((i) => i.label);
    expect(labels).toContain('"census"');
  });

  it("completes the include: keyword", () => {
    const src = "reverse_geocode(point(1, 2), ";
    const labels = getCompletions(src, 1, src.length + 1).map((i) => i.label);
    expect(labels).toContain("include");
  });
});

describe("overlap_fraction — completions, hover, signatures", () => {
  it("offers .overlap_fraction( as a method", () => {
    const src = "search(node).";
    const item = getCompletions(src, 1, src.length + 1).find((i) => i.label === "overlap_fraction");
    expect(item?.insertText).toBe("overlap_fraction(");
  });

  it.each(["search(node).sum(", "search(node).sort(", "search(node).group_by(", "search(node).filter("])(
    "offers overlap_fraction( inside %s",
    (src) => {
      const labels = getCompletions(src, 1, src.length + 1).map((i) => i.label);
      expect(labels).toContain("overlap_fraction(");
    },
  );

  it("offers polygon(, bbox( and polygon variables inside overlap_fraction(", () => {
    const src = `${ISO}search(node).sum(overlap_fraction(`;
    const labels = getCompletions(src, 2, "search(node).sum(overlap_fraction(".length + 1).map(
      (i) => i.label,
    );
    expect(labels).toEqual(expect.arrayContaining(["polygon(", "bbox(", "$area"]));
  });

  it("hovers the expression function and the method differently", () => {
    const src = "search(node).overlap_fraction($a).sum(overlap_fraction($a));";
    const methodHover = getHover(src, 1, 16);
    expect(methodHover?.contents).toContain(".overlap_fraction(");
    const fnHover = getHover(src, 1, 42);
    expect(fnHover?.contents).toContain("overlap_fraction(geometry: Polygon | Bbox | $var | $$.name) → number");
  });

  it("shows signature help inside overlap_fraction(", () => {
    const src = "search(node).sum(overlap_fraction(";
    const help = getSignatureHelp(src, 1, src.length + 1);
    expect(help?.signatures[0]?.label).toContain("overlap_fraction(geometry");
  });
});

describe("overlap_fraction — formatter", () => {
  it.each([
    `${ISO}\nsearch(node).sum(number(t["population"]) * overlap_fraction($area));\n`,
    "search(node).filter(overlap_fraction($$.area) > 0.5);\n",
    "search(node).overlap_fraction($$.area);\n",
    'reverse_geocode(point(40.7484, -73.9856), include: "census");\n',
  ])("round-trips %s", (src) => {
    const { ast } = parse(src);
    expect(typeof ast).toBe("object");
    expect(formatDocument(src)).toBe(src);
  });

  it("round-trips the bbox form", () => {
    const src =
      "search(node)\n  .sort(by: overlap_fraction(bbox(40.7, -74.02, 40.75, -73.97)), order: :desc);\n";
    expect(formatDocument(src)).toBe(src);
  });
});
