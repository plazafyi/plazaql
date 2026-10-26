import { describe, expect, it } from "vitest"
import { getHover } from "../src/hover.js"
import { parse } from "../src/parser.js"
import { typeCheck } from "../src/type-checker.js"

function check(source: string) {
  const { ast, errors: parseErrors } = parse(source)
  expect(parseErrors).toHaveLength(0)
  return typeCheck(ast)
}

const od = "origin: point(38.8, -77.1), destination: point(38.8, -77.09)"

describe("computation keyword allowlist", () => {
  it("names the computation for an unknown keyword", () => {
    const { errors } = check(`route(${od}, foo: 1);`)
    expect(errors).toHaveLength(1)
    expect(errors[0].message).toBe("`route()` does not accept `foo:`")
    expect(errors[0].hint).toContain("`depart_at:`")
  })

  it("refuses a keyword the computation ignores", () => {
    const { errors } = check('nearest(point: point(1, 2), type: "node");')
    expect(errors.map((e) => e.message)).toEqual([
      "`nearest()` does not accept `type:`",
    ])
  })

  it("accepts every REST option of route and ev_route", () => {
    expect(
      check(
        `route(${od}, mode: "foot", steps: true, alternatives: 2, depart_at: "now", traffic_model: "pessimistic", exclude: ["toll"]);`,
      ).errors,
    ).toHaveLength(0)
    expect(
      check(
        `ev_route(${od}, battery: 60000, min_charge_pct: 10, connector_types: ["ccs"], exclude: ["toll"]);`,
      ).errors,
    ).toHaveLength(0)
  })
})

describe("REST options as keywords", () => {
  it("accepts the REST options each computation takes", () => {
    for (const source of [
      `route(${od}, overview: "simplified", geometries: "polyline6", annotations: true);`,
      "isochrone(center: point(1, 2), time: [60, 90], denoise: 10, generalize: 5);",
      'matrix(origins: [point(1, 2)], destinations: [point(3, 4)], annotations: "distance", fallback_speed: 30);',
      "map_match(points: [point(1, 2), point(3, 4)], radiuses: [10, 20]);",
      'geocode("Berlin", lang: "de", layer: "poi");',
      'geocode(addresses: ["a", "b"]);',
      'reverse_geocode(point(1, 2), lang: "de", layer: "address");',
    ]) {
      expect(check(source).errors, source).toHaveLength(0)
    }
  })

  it("refuses an option on a computation that ignores it", () => {
    const { errors } = check("isochrone(center: point(1, 2), time: 60, fallback_speed: 3);")
    expect(errors[0].message).toBe("`isochrone()` does not accept `fallback_speed:`")
  })
})

describe("number lists after a keyword", () => {
  it("parse in methods and computations", () => {
    for (const source of [
      "search(node).limit(count: [1, 2]);",
      "map_match(points: [point(1, 2), point(3, 4)], radiuses: [10]);",
    ]) {
      const { errors } = parse(source)
      expect(errors, source).toHaveLength(0)
    }
  })
})

describe("output shape and accessors", () => {
  it("accepts .geometry(false) and .include()", () => {
    expect(
      check('search(node).include("bbox", "center").geometry(false);').errors,
    ).toHaveLength(0)
  })

  it('parses p["key"] like t["key"]', () => {
    expect(
      check('search(node).filter(number(p["pop"]) > 3).sort(p["name"]);')
        .errors,
    ).toHaveLength(0)
  })

  it('accepts p["key"] in group_by, aggregates and dataset searches', () => {
    for (const src of [
      'search(node).group_by(p["cuisine"]).count();',
      'search(way).group_by(p["kind"]).sum(number(p["seats"]));',
      'search(way).avg(number(p["height"]));',
      'search(dataset("census-tracts")).filter(number(p["population"]) > 5000).sort(p["name"]);',
    ]) {
      expect(check(src).errors).toHaveLength(0)
    }
  })

  it("allows only aggregations after group_by", () => {
    expect(check('search(node).group_by(t["cuisine"]).count();').errors).toHaveLength(0)
    expect(check('search(node).group_by(t["cuisine"]).limit(3);').errors).toHaveLength(1)
  })

  it('hovers t["key"] and p["key"] as tag accessors', () => {
    const src = 'search(node).sort(p["name"]).filter(t["a"] == "x");'
    expect(getHover(src, 1, 19)?.contents).toContain('p["key"]')
    expect(getHover(src, 1, 19)?.contents).toContain('Same accessor as t["key"]')
    expect(getHover(src, 1, 37)?.contents).toContain('t["key"]')
  })

  it("does not treat a variable named p as the accessor", () => {
    expect(getHover("$p = point(1, 2); search(node).around(10, $p);", 1, 2)?.contents).not.toContain(
      'p["key"]',
    )
  })

  it("accepts geometry and number variables", () => {
    expect(
      check("$r = 100; $p = point(1, 2); search(node).around($r, $p);").errors,
    ).toHaveLength(0)
    expect(
      check("$z = polygon(point(1, 2), point(1, 3), point(2, 3)); search(node).within($z);")
        .errors,
    ).toHaveLength(0)
  })

  it("accepts .crosses(linestring(...))", () => {
    expect(
      check("search(way).crosses(linestring(point(1, 2), point(3, 4)));")
        .errors,
    ).toHaveLength(0)
  })
})
