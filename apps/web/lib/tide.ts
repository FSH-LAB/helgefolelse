import type { Trend } from "./helgefolelse";

export interface Tide {
  /** Above the surface. */
  air: string;
  /** The water at the surface. */
  surface: string;
  /** The water at the bottom of the viewport. */
  deep: string;
}

interface Stop extends Tide {
  at: number;
}

const FLOODING: Stop[] = [
  { at: 0, air: "#101d22", surface: "#0a3a40", deep: "#072226" },
  { at: 35, air: "#16262c", surface: "#0b5f63", deep: "#072f33" },
  { at: 70, air: "#1b3138", surface: "#109089", deep: "#0a4a4c" },
  { at: 100, air: "#24424a", surface: "#17a39b", deep: "#0c5a58" },
];

const EBBING: Stop[] = [
  { at: 0, air: "#080f17", surface: "#071a26", deep: "#040a11" },
  { at: 30, air: "#0e1a26", surface: "#0a3145", deep: "#061c28" },
  { at: 65, air: "#162836", surface: "#0e5e6b", deep: "#08313c" },
  { at: 100, air: "#24424a", surface: "#17a39b", deep: "#0c5a58" },
];

function channels(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function mix(a: string, b: string, t: number): string {
  const [ar, ag, ab] = channels(a);
  const [br, bg, bb] = channels(b);
  const blend = (x: number, y: number) => Math.round(x + (y - x) * t);
  return `rgb(${blend(ar, br)} ${blend(ag, bg)} ${blend(ab, bb)})`;
}

export function tideFor(value: number, trend: Trend): Tide {
  const stops = trend === "falling" ? EBBING : FLOODING;
  const v = Math.min(100, Math.max(0, value));

  let lower = stops[0];
  let upper = stops[stops.length - 1];
  for (let i = 0; i < stops.length - 1; i++) {
    if (v >= stops[i].at && v <= stops[i + 1].at) {
      lower = stops[i];
      upper = stops[i + 1];
      break;
    }
  }

  const span = upper.at - lower.at;
  const t = span === 0 ? 0 : (v - lower.at) / span;

  return {
    air: mix(lower.air, upper.air, t),
    surface: mix(lower.surface, upper.surface, t),
    deep: mix(lower.deep, upper.deep, t),
  };
}
