import { describe, expect, it } from "vitest";
import { getCompletions } from "../src/completions.js";
import { parse } from "../src/parser.js";
import { typeCheck } from "../src/type-checker.js";

function check(source: string) {
  const { ast, errors: parseErrors } = parse(source);
  expect(parseErrors).toHaveLength(0);
  return typeCheck(ast);
}

describe(".tile(z, x, y)", () => {
  it("accepts a tile output on a search", () => {
    const result = check(
      'search(node, amenity: "cafe").fields("name").tile(14, 4823, 6160, layers: ["pois"]);',
    );
    expect(result.errors).toHaveLength(0);
  });

  it("is terminal: nothing may follow it", () => {
    const result = check('search(node, amenity: "cafe").tile(14, 4823, 6160).limit(5);');
    expect(result.errors.length).toBeGreaterThan(0);
  });

  it("conflicts with another output mode", () => {
    const result = check('search(node, amenity: "cafe").count().tile(2, 1, 1);');
    expect(result.errors.length).toBeGreaterThan(0);
  });

  it("only applies to search results", () => {
    const result = check('boundary(name: "Paris").tile(2, 1, 1);');
    expect(result.errors.some((e) => e.message.includes("`.tile()` cannot be applied"))).toBe(
      true,
    );
  });

  it("is offered as a method completion", () => {
    const source = 'search(node, amenity: "cafe").';
    const items = getCompletions(source, 1, source.length + 1);
    expect(items.some((i) => i.label === "tile")).toBe(true);
  });
});
