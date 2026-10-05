export function GET() {
  return Response.json({ status: "ok", commit: process.env.GIT_SHA ?? null });
}
