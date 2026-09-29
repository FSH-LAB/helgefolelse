import type { Band } from "./helgefolelse";

/** The depth staff, shallow to deep. */
export const BAND_ORDER: Band[] = ["ankle", "knee", "waist", "chest", "over"];

const BANDS: Record<Band, string> = {
  ankle: "Ankeldypt",
  knee: "Knedypt",
  waist: "Midjedypt",
  chest: "Brystdypt",
  over: "Over hodet",
};

export function bandLabel(band: Band): string {
  return BANDS[band];
}
