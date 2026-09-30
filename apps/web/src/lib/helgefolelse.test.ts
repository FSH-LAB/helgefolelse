import { describe, expect, it } from "vitest";
import { read } from "./helgefolelse";

describe("weekend feeling", () => {
  it("starts the week at zero in Oslo", () => {
    expect(read(new Date("2026-09-27T22:00:00Z"))).toMatchObject({
      value: 0,
      trend: "rising",
      band: "ankle",
      weekday: 1,
      hour: 0,
    });
  });

  it("holds at 100 from Friday 16:00 through Saturday in Oslo", () => {
    for (const instant of ["2026-10-02T14:00:00Z", "2026-10-03T21:59:00Z"]) {
      expect(read(new Date(instant))).toMatchObject({
        value: 100,
        trend: "holding",
        band: "over",
      });
    }
  });

  it("starts falling at Sunday midnight", () => {
    const start = read(new Date("2026-10-03T22:00:00Z"));
    const evening = read(new Date("2026-10-04T18:00:00Z"));
    expect(start).toMatchObject({ value: 100, trend: "falling", weekday: 7 });
    expect(evening.value).toBeLessThan(start.value);
    expect(evening.value).toBeGreaterThan(0);
  });

  it("uses Oslo local time after the daylight-saving transition", () => {
    expect(read(new Date("2026-03-29T22:00:00Z"))).toMatchObject({
      value: 0,
      weekday: 1,
      hour: 0,
      minute: 0,
    });
  });
});