"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import { read, type Reading } from "@/lib/helgefolelse";
import { BAND_ORDER, bandLabel } from "@/lib/copy";
import { tideFor } from "@/lib/tide";

const SWEEP_MS = 1600;
/** The surface needs a real frame rate; the fourth decimal is happy to share. */
const FRAME_MS = 33;
const CALM_FRAME_MS = 1000;

/**
 * Two slow sines of different period and opposite drift, so the surface never
 * visibly repeats. Amplitude is a fraction of viewport height; period is
 * counted in full waves across the width.
 */
const WAVES = [
  { amplitude: 0.014, periods: 1.35, cyclesPerSecond: 0.05 },
  { amplitude: 0.008, periods: 2.4, cyclesPerSecond: -0.083 },
];
const SAMPLES = 48;

/** Minor graduations up the staff, skipping the five that carry a label. */
const MINOR = Array.from({ length: 21 }, (_, i) => i * 5).filter(
  (v) => v % 20 !== 10,
);

const TAU = Math.PI * 2;

function surfaceY(x: number, w: number, h: number, level: number, t: number) {
  let y = level;
  for (const { amplitude, periods, cyclesPerSecond } of WAVES) {
    y +=
      amplitude *
      h *
      Math.sin((x / w) * periods * TAU + t * cyclesPerSecond * TAU);
  }
  return y;
}

function surface(w: number, h: number, level: number, t: number) {
  const points: string[] = [];
  for (let i = 0; i <= SAMPLES; i++) {
    const x = (i / SAMPLES) * w;
    points.push(`${x.toFixed(1)} ${surfaceY(x, w, h, level, t).toFixed(1)}`);
  }
  const line = `M ${points.join(" L ")}`;
  // Closed a little past the bottom edge so no hairline shows under the water.
  return { line, body: `${line} L ${w} ${h + 2} L 0 ${h + 2} Z` };
}

interface Box {
  w: number;
  h: number;
}

export default function Tide({ initial }: { initial: Reading }) {
  const scene = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState<Box | null>(null);
  const [frame, setFrame] = useState({ reading: initial, swept: 0, clock: 0 });

  useEffect(() => {
    const element = scene.current;
    if (!element) return;
    // ResizeObserver fires once on observe, which is also the first measurement.
    const observer = new ResizeObserver(([entry]) => {
      const { width, height } = entry.contentRect;
      setBox({ w: Math.round(width), h: Math.round(height) });
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const begun = performance.now();
    let raf = 0;
    let painted = 0;

    const tick = (now: number) => {
      const p = calm ? 1 : Math.min(1, (now - begun) / SWEEP_MS);
      const settled = p >= 1;
      const due = now - painted >= (calm ? CALM_FRAME_MS : FRAME_MS);

      if (!settled || due) {
        painted = now;
        setFrame({
          reading: read(),
          // Ease out hard, no overshoot: the tide must never crest past full.
          swept: settled ? 1 : 1 - Math.pow(2, -10 * p),
          clock: calm ? 0 : (now - begun) / 1000,
        });
      }
      raf = requestAnimationFrame(tick);
    };

    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);

  const { reading, swept, clock } = frame;
  const value = reading.value * swept;
  const [whole, fraction] = value.toFixed(4).split(".");
  const tide = tideFor(value, reading.trend);
  const lit =
    BAND_ORDER[Math.min(BAND_ORDER.length - 1, Math.floor(value / 20))];

  const narrow = !!box && box.w < 560;
  const staff = narrow
    ? { width: 48, rule: 18, minor: 26, major: 36 }
    : { width: 72, rule: 30, minor: 41, major: 57 };
  const staffWidth = staff.width;
  const region = box ? box.w - staffWidth : 0;
  // Widest the readout ever gets is "100" plus the tail, in ems of the numeral.
  const WIDEST = 3 * 0.62 + 0.26 * 0.55 * 5 + 0.15 * 0.9 + 0.07;
  const numeralSize = box
    ? Math.min((region * 0.88) / WIDEST, box.h * 0.34)
    : 0;
  const sea = box
    ? surface(box.w, box.h, box.h * (1 - value / 100), clock)
    : null;
  const numeralX = box ? staffWidth + (box.w - staffWidth) / 2 : 0;
  const numeralY = box ? box.h / 2 + numeralSize * 0.36 : 0;

  return (
    <div
      className="scene"
      ref={scene}
      style={
        {
          "--air": tide.air,
          "--surface": tide.surface,
          "--deep": tide.deep,
          "--staff": `${staffWidth}px`,
        } as CSSProperties
      }
    >
      {box ? (
        <svg
          className="sea"
          width={box.w}
          height={box.h}
          viewBox={`0 0 ${box.w} ${box.h}`}
          aria-hidden
        >
          <defs>
            <linearGradient id="depth" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" style={{ stopColor: "var(--surface)" }} />
              <stop offset="100%" style={{ stopColor: "var(--deep)" }} />
            </linearGradient>
            <clipPath id="submerged">
              <path d={sea!.body} />
            </clipPath>
          </defs>

          <path className="water" d={sea!.body} />
          <path className="waterline" d={sea!.line} />

          <g className="staff">
            <line
              className="staff-rule"
              x1={staff.rule}
              y1={0}
              x2={staff.rule}
              y2={box.h}
            />
            {MINOR.map((v) => {
              const y = box.h * (1 - v / 100);
              return (
                <line
                  key={v}
                  className="staff-minor"
                  x1={staff.rule}
                  y1={y}
                  x2={staff.minor}
                  y2={y}
                />
              );
            })}
            {BAND_ORDER.map((band, i) => {
              const y = box.h * (1 - (i * 20 + 10) / 100);
              return (
                <g
                  key={band}
                  className={band === lit ? "mark mark--lit" : "mark"}
                >
                  <line x1={staff.rule} y1={y} x2={staff.major} y2={y} />
                </g>
              );
            })}
          </g>

          {/* Drawn twice: hollow in the air, solid once the water reaches it. */}
          <text
            className="readout readout--air"
            x={numeralX}
            y={numeralY}
            textAnchor="middle"
            style={{ fontSize: numeralSize, strokeWidth: numeralSize * 0.022 }}
          >
            <tspan>{whole}</tspan>
            {/* The small parts get a finer outline, or their counters fill in. */}
            <tspan
              style={{
                fontSize: numeralSize * 0.26,
                strokeWidth: numeralSize * 0.009,
              }}
            >
              .{fraction}
            </tspan>
            <tspan
              style={{
                fontSize: numeralSize * 0.15,
                strokeWidth: numeralSize * 0.007,
              }}
              dx={numeralSize * 0.07}
            >
              %
            </tspan>
          </text>
          <text
            className="readout readout--sea"
            clipPath="url(#submerged)"
            x={numeralX}
            y={numeralY}
            textAnchor="middle"
            style={{ fontSize: numeralSize }}
          >
            <tspan>{whole}</tspan>
            <tspan style={{ fontSize: numeralSize * 0.26 }}>.{fraction}</tspan>
            <tspan
              style={{ fontSize: numeralSize * 0.15 }}
              dx={numeralSize * 0.07}
            >
              %
            </tspan>
          </text>
        </svg>
      ) : null}

      <div className="frame">
        <header className="chrome">
          <p className="wordmark">helgefølelse</p>
        </header>

        <footer>
          <p className="sr-only">{`${Math.round(value)} % — ${bandLabel(lit)}`}</p>
        </footer>
      </div>
    </div>
  );
}
