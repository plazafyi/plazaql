import { describe, it, expect } from "vitest";
import { OSM_TAG_DATABASE, TAG_KEY_MAP } from "../src/osm-tags.js";

describe("OSM Tag Database", () => {
  it("has no duplicate keys", () => {
    const keys = OSM_TAG_DATABASE.map((t) => t.key);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("every entry has non-empty key, description, and rank", () => {
    for (const tag of OSM_TAG_DATABASE) {
      expect(tag.key.length).toBeGreaterThan(0);
      expect(tag.description.length).toBeGreaterThan(0);
      expect(tag.rank).toBeGreaterThan(0);
    }
  });

  it("ranks are unique", () => {
    const ranks = OSM_TAG_DATABASE.map((t) => t.rank);
    expect(new Set(ranks).size).toBe(ranks.length);
  });

  it("TAG_KEY_MAP has same count as OSM_TAG_DATABASE", () => {
    expect(TAG_KEY_MAP.size).toBe(OSM_TAG_DATABASE.length);
  });

  it("TAG_KEY_MAP lookups return correct entries", () => {
    expect(TAG_KEY_MAP.get("amenity")?.key).toBe("amenity");
    expect(TAG_KEY_MAP.get("shop")?.key).toBe("shop");
    expect(TAG_KEY_MAP.get("highway")?.key).toBe("highway");
    expect(TAG_KEY_MAP.get("nonexistent")).toBeUndefined();
  });

  it("all former COMMON_TAG_KEYS are present in new database", () => {
    const oldKeys = [
      "amenity", "name", "building", "highway", "shop", "tourism", "leisure",
      "natural", "landuse", "waterway", "railway", "aeroway", "boundary", "place",
      "addr:street", "addr:housenumber", "addr:city", "addr:postcode",
      "cuisine", "sport", "religion", "surface", "access", "wheelchair",
      "opening_hours", "phone", "website", "operator", "brand",
    ];
    for (const key of oldKeys) {
      expect(TAG_KEY_MAP.has(key), `missing key: ${key}`).toBe(true);
    }
  });

  it("high-priority keys have populated values", () => {
    expect(TAG_KEY_MAP.get("amenity")!.values.length).toBeGreaterThanOrEqual(40);
    expect(TAG_KEY_MAP.get("shop")!.values.length).toBeGreaterThanOrEqual(30);
    expect(TAG_KEY_MAP.get("highway")!.values.length).toBeGreaterThanOrEqual(20);
    expect(TAG_KEY_MAP.get("tourism")!.values.length).toBeGreaterThanOrEqual(10);
    expect(TAG_KEY_MAP.get("leisure")!.values.length).toBeGreaterThanOrEqual(10);
  });

  it("freeform keys are marked as freeform", () => {
    for (const key of ["name", "brand", "operator", "ref", "phone", "website"]) {
      expect(TAG_KEY_MAP.get(key)?.freeform, `${key} should be freeform`).toBe(true);
    }
  });

  it("all documented tags from plaza-docs are present", () => {
    const docTags = [
      "amenity", "shop", "tourism", "leisure", "highway", "railway", "natural",
      "waterway", "boundary", "building", "cuisine", "sport", "religion",
      "surface", "access", "wheelchair", "brand", "operator", "historic",
      "place", "landuse", "aeroway", "cycleway", "bicycle", "maxheight",
      "maxweight", "hgv", "internet_access", "outdoor_seating", "organic",
      "diet:vegan", "drive_through", "building:levels", "route", "type",
      "admin_level", "bridge",
    ];
    for (const key of docTags) {
      expect(TAG_KEY_MAP.has(key), `missing documented tag: ${key}`).toBe(true);
    }
  });

  it("all documented tag VALUES from plaza-docs are present", () => {
    const docValues: Record<string, string[]> = {
      amenity: ["cafe", "restaurant", "pharmacy", "hospital", "school", "fuel", "atm",
        "fire_station", "charging_station", "pub", "bar", "fast_food", "bank",
        "post_office", "library", "kindergarten", "bench"],
      shop: ["supermarket", "convenience", "greengrocer", "grocery", "bicycle"],
      tourism: ["museum", "viewpoint", "attraction"],
      leisure: ["park", "playground", "garden"],
      highway: ["bus_stop", "cycleway", "primary", "secondary", "trunk", "motorway"],
      railway: ["station", "subway_entrance", "tram_stop"],
      natural: ["coastline", "peak", "water"],
      waterway: ["river", "waterfall"],
      building: ["yes", "residential"],
      cuisine: ["italian", "burger", "pizza"],
    };
    for (const [key, values] of Object.entries(docValues)) {
      const tagInfo = TAG_KEY_MAP.get(key);
      expect(tagInfo, `missing key: ${key}`).toBeDefined();
      const tagValues = tagInfo!.values.map((v) => v.value);
      for (const val of values) {
        expect(tagValues, `${key} missing value: ${val}`).toContain(val);
      }
    }
  });
});
