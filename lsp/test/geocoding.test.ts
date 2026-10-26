import { describe, expect, it } from "vitest";
import { getCompletions } from "../src/completions.js";
import { parse } from "../src/parser.js";
import { typeCheck } from "../src/type-checker.js";

function check(source: string) {
  const { ast, errors: parseErrors } = parse(source);
  expect(parseErrors).toHaveLength(0);
  return typeCheck(ast);
}

describe("structured geocode()", () => {
  it("accepts structured components without query text", () => {
    const result = check(
      '$$ = geocode(address: "1600 Pennsylvania Ave", locality: "Washington", region: "DC", postalcode: "20500", country: "US");',
    );
    expect(result.errors).toHaveLength(0);
  });

  it("accepts a numeric postalcode", () => {
    expect(check('$$ = geocode(locality: "Boston", postalcode: 2134);').errors).toHaveLength(0);
  });

  it("rejects geocode() with neither text nor a component", () => {
    const result = check('$$ = geocode(country: "US");');
    expect(result.errors.some((e) => e.message.includes("needs an address string"))).toBe(true);
  });

  it("rejects a non-string component", () => {
    const result = check("$$ = geocode(locality: 42);");
    expect(result.errors.some((e) => e.message.includes("`locality:` must be a string"))).toBe(
      true,
    );
  });
});

describe("geocode() and autocomplete() filters", () => {
  it("accepts layers as a string or a list, and a relation boundary_gid", () => {
    for (const src of [
      '$$ = geocode("Main St", layers: "address,poi", boundary_gid: "osm:relation:62422");',
      '$$ = autocomplete("Cafe", layers: ["poi"], boundary_gid: "osm:way:42");',
    ]) {
      expect(check(src).errors).toHaveLength(0);
    }
  });

  it("rejects an unknown layer", () => {
    const result = check('$$ = geocode("Main St", layers: ["venue"]);');
    expect(result.errors.some((e) => e.message.includes('unknown `layers:` value "venue"'))).toBe(
      true,
    );
  });

  it("rejects a node boundary_gid", () => {
    const result = check('$$ = geocode("Main St", boundary_gid: "osm:node:1");');
    expect(result.errors.some((e) => e.message.includes("invalid `boundary_gid:`"))).toBe(true);
  });
});

describe("place_lookup()", () => {
  it("parses as a computation and accepts positional GIDs or ids:", () => {
    for (const src of [
      '$$ = place_lookup("osm:node:123", "osm:way:456");',
      '$$ = place_lookup(ids: ["osm:relation:789", "osm:address:5"]);',
    ]) {
      expect(check(src).errors).toHaveLength(0);
    }
  });

  it("rejects a malformed GID", () => {
    const result = check('$$ = place_lookup("node/123");');
    expect(result.errors.some((e) => e.message.includes('invalid GID "node/123"'))).toBe(true);
  });

  it("rejects GIDs longer than a bigint", () => {
    const result = check('$$ = place_lookup("osm:node:12345678901234567890");');
    expect(result.errors.some((e) => e.message.includes("invalid GID"))).toBe(true);
    const boundary = check(
      '$$ = geocode("Cafe", boundary_gid: "osm:relation:12345678901234567890");',
    );
    expect(boundary.errors.some((e) => e.message.includes("invalid `boundary_gid:`"))).toBe(true);
  });

  it("rejects a call with no GIDs", () => {
    const result = check("$$ = place_lookup();");
    expect(result.errors.some((e) => e.message.includes("at least one GID"))).toBe(true);
  });

  it("can feed a spatial filter like any point set", () => {
    const result = check(
      '$home = place_lookup("osm:node:123");\n$$ = search(node, amenity: "cafe").around(500, $home);',
    );
    expect(result.errors).toHaveLength(0);
  });
});

describe("completions", () => {
  it("suggests structured components and filters inside geocode(", () => {
    const src = "$$ = geocode(";
    const labels = getCompletions(src, 1, src.length + 1).map((i) => i.label);
    for (const label of ["address", "locality", "region", "postalcode", "layers", "boundary_gid"]) {
      expect(labels).toContain(label);
    }
  });

  it("offers place_lookup at the top level", () => {
    const labels = getCompletions("", 1, 1).map((i) => i.label);
    expect(labels).toContain("place_lookup");
  });
});

describe("dataset keywords", () => {
  it("accepts datasets:, dataset_name_field: and avoid_datasets: where they apply", () => {
    for (const src of [
      '$$ = geocode("Main St", datasets: ["census-places", "all"], layers: "dataset");',
      '$$ = geocode(locality: "Springfield", datasets: "plaza", dataset_name_field: "title");',
      '$$ = autocomplete("Gold", datasets: ["my-stores"]);',
      '$$ = reverse_geocode(point(38.9, -77.0), datasets: ["census-tracts"]);',
      '$$ = route(origin: point(38.8, -77.1), destination: point(38.8, -77.0), avoid_datasets: ["flood-zones"]);',
      '$$ = isochrone(center: point(38.8, -77.1), time: 600, avoid_datasets: "flood-zones");',
      '$$ = matrix(origins: [point(38.8, -77.1)], destinations: [point(38.8, -77.0)], avoid_datasets: ["a"]);',
    ]) {
      expect(check(src).errors).toEqual([]);
    }
  });

  it("rejects dataset keywords on computations that don't take them", () => {
    const route = check(
      '$$ = route(origin: point(38.8, -77.1), destination: point(38.8, -77.0), datasets: ["x"]);',
    );
    expect(route.errors.map((e) => e.message)).toContain(
      "`route()` does not accept `datasets:`",
    );

    const geocode = check('$$ = geocode("Main St", avoid_datasets: ["x"]);');
    expect(geocode.errors.map((e) => e.message)).toContain(
      "`geocode()` does not accept `avoid_datasets:`",
    );
  });

  it("rejects non-string values", () => {
    expect(check('$$ = geocode("Main St", datasets: 5);').errors.map((e) => e.message)).toContain(
      "`datasets:` must be a string or a list of strings",
    );
    expect(
      check('$$ = geocode("Main St", datasets: ["a", 5]);').errors.map((e) => e.message),
    ).toContain("`datasets:` list items must be strings");
    expect(
      check('$$ = geocode("Main St", dataset_name_field: 5);').errors.map((e) => e.message),
    ).toContain("`dataset_name_field:` must be a string");
  });
});
