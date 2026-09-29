/**
 * The weekend-feeling curve: how deep you are standing in the weekend.
 *
 * The week:
 *   Mon 00:00 -> Fri 16:00   exponential rise, 0 -> 100
 *   Fri 16:00 -> Sun 00:00   held at 100
 *   Sun 00:00 -> Mon 00:00   exponential fall, 100 -> 0 (late and steep)
 */

const TIME_ZONE = "Europe/Oslo";

/** Hours into the week (Monday 00:00 = 0) at which the rise tops out. */
const RISE_END = 4 * 24 + 16;
/** Hours into the week at which the plateau ends and Sunday starts eroding. */
const PLATEAU_END = 6 * 24;
const WEEK = 7 * 24;

/** Steepness of the climb. Higher means a flatter Monday and a sharper Friday. */
const RISE_SHAPE = 3;
/** Steepness of the Sunday collapse. Higher means the drop waits until evening. */
const FALL_SHAPE = 4.5;

export type Trend = "rising" | "holding" | "falling";
export type Band = "ankle" | "knee" | "waist" | "chest" | "over";

export interface Reading {
  /** 0–100. */
  value: number;
  trend: Trend;
  band: Band;
  /** 1 = Monday … 7 = Sunday, in Oslo. */
  weekday: number;
  /** Oslo wall-clock hour, 0–23. */
  hour: number;
  /** Oslo wall-clock minute, 0–59. */
  minute: number;
}

const WEEKDAY_INDEX: Record<string, number> = {
  Mon: 1,
  Tue: 2,
  Wed: 3,
  Thu: 4,
  Fri: 5,
  Sat: 6,
  Sun: 7,
};

const osloParts = new Intl.DateTimeFormat("en-GB", {
  timeZone: TIME_ZONE,
  weekday: "short",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
});

/** Normalised exponential ease from 0 to 1 over p, steepening as p grows. */
function ramp(p: number, shape: number): number {
  return (Math.exp(shape * p) - 1) / (Math.exp(shape) - 1);
}

function bandFor(value: number): Band {
  if (value < 20) return "ankle";
  if (value < 40) return "knee";
  if (value < 60) return "waist";
  if (value < 80) return "chest";
  return "over";
}

export function read(at: Date = new Date()): Reading {
  const parts = osloParts.formatToParts(at);
  const get = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((p) => p.type === type)?.value ?? "0";

  const weekday = WEEKDAY_INDEX[get("weekday")] ?? 1;
  const hour = Number(get("hour")) % 24;
  const minute = Number(get("minute"));
  const second = Number(get("second"));

  const hours =
    (weekday - 1) * 24 +
    hour +
    minute / 60 +
    second / 3600 +
    at.getMilliseconds() / 3_600_000;

  let value: number;
  let trend: Trend;

  if (hours < RISE_END) {
    value = 100 * ramp(hours / RISE_END, RISE_SHAPE);
    trend = "rising";
  } else if (hours < PLATEAU_END) {
    value = 100;
    trend = "holding";
  } else {
    const p = (hours - PLATEAU_END) / (WEEK - PLATEAU_END);
    value = 100 * (1 - ramp(p, FALL_SHAPE));
    trend = "falling";
  }

  value = Math.min(100, Math.max(0, value));

  return { value, trend, band: bandFor(value), weekday, hour, minute };
}
