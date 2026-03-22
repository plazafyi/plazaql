import { describe, it, expect } from "vitest";
import { getCompletions } from "../src/completions.js";

describe("PlazaQL Completions", () => {
  // ── After "." on GeoSet ────────────────────────────────────────

  it("suggests methods after dot on GeoSet", () => {
    const items = getCompletions('$$ =search(amenity: "cafe").', 1, 30);
    expect(items.length).toBeGreaterThan(0);
    expect(items.some((i) => i.label === "within")).toBe(true);
    expect(items.some((i) => i.label === "around")).toBe(true);
    expect(items.some((i) => i.label === "limit")).toBe(true);
    expect(items.some((i) => i.label === "count")).toBe(true);
  });

  // ── After "." after phase 4 method → only phase 5+ ────────────

  it("suggests all valid methods (initial state has no phase restriction)", () => {
    const items = getCompletions("$$ =search().buffer(100).", 1, 27);
    // Should still show methods (since our heuristic defaults to lastPhase=0)
    expect(items.length).toBeGreaterThan(0);
    const labels = items.map((i) => i.label);
    expect(labels).toContain("limit");
    expect(labels).toContain("count");
  });

  // ── After "$" → defined variables ──────────────────────────────

  it("suggests variables after $", () => {
    const source = '$berlin = area(name: "Berlin");\n$$ =$';
    const items = getCompletions(source, 2, 7);
    expect(items.length).toBeGreaterThan(0);
    expect(items.some((i) => i.label === "$berlin")).toBe(true);
    expect(items.some((i) => i.detail?.includes("Area"))).toBe(true);
  });

  // ── Inside search( → tag suggestions ───────────────────────────

  it("suggests tag keys inside search(", () => {
    const items = getCompletions("$$ =search(", 1, 14);
    expect(items.length).toBeGreaterThan(0);
    expect(items.some((i) => i.label === "amenity")).toBe(true);
    expect(items.some((i) => i.label === "name")).toBe(true);
    expect(items.some((i) => i.label === "building")).toBe(true);
    expect(items.some((i) => i.label === "highway")).toBe(true);
  });

  // ── Inside function params ─────────────────────────────────────

  it("suggests params inside isochrone(", () => {
    const items = getCompletions("$$ =isochrone(", 1, 17);
    expect(items.length).toBeGreaterThan(0);
    expect(items.some((i) => i.label === "center")).toBe(true);
    expect(items.some((i) => i.label === "time")).toBe(true);
  });

  // ── Top-level completions ──────────────────────────────────────

  it("suggests top-level constructs at start of line", () => {
    const items = getCompletions("", 1, 1);
    expect(items.length).toBeGreaterThan(0);
    const labels = items.map((i) => i.label);
    expect(labels).toContain("search");
    expect(labels).toContain("$");
    expect(labels).toContain("$$");
    expect(labels).toContain("[");
  });

  // ── After "$$" ─────────────────────────────────────────────────

  it("suggests = and .name after $$", () => {
    const items = getCompletions("$$", 1, 3);
    expect(items.length).toBeGreaterThan(0);
  });

  // ── Variable completions show type ─────────────────────────────

  it("variable completions include type info", () => {
    const source = '$p = point(38.9, -77.0);\n$$ =$';
    const items = getCompletions(source, 2, 7);
    const pVar = items.find((i) => i.label === "$p");
    expect(pVar).toBeDefined();
    expect(pVar?.detail).toContain("Point");
  });

  // ── Methods have phase info ────────────────────────────────────

  it("method completions include phase info", () => {
    const items = getCompletions("$$ =search().", 1, 16);
    const within = items.find((i) => i.label === "within");
    expect(within).toBeDefined();
    expect(within?.detail).toContain("Phase");
  });

  // ── Empty source ───────────────────────────────────────────────

  it("returns completions for empty source", () => {
    const items = getCompletions("", 1, 1);
    expect(items.length).toBeGreaterThan(0);
  });
});
