import Tide from "./tide";
import { read } from "@/lib/helgefolelse";

// The reading is the whole page, so it must be taken per request rather than
// baked in at build time.
export const dynamic = "force-dynamic";

export default function Home() {
  return <Tide initial={read()} />;
}
