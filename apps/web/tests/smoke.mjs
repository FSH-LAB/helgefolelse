import assert from "node:assert/strict";
import { setTimeout } from "node:timers/promises";
import { test } from "node:test";

const baseUrl = process.env.SMOKE_URL;
const commit = process.env.SHA;
assert.ok(baseUrl, "SMOKE_URL must point to a running app");
assert.match(commit ?? "", /^[0-9a-f]{40}$/, "SHA must be a full commit SHA");

async function request(path) {
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetch(new URL(path, baseUrl), {
        signal: AbortSignal.timeout(5_000),
      });
      assert.equal(response.status, 200, `${path} must return HTTP 200`);
      return await response.text();
    } catch (error) {
      if (attempt === 10) throw error;
      await setTimeout(2_000);
    }
  }
}

test("health reports the deployed commit", { timeout: 90_000 }, async () => {
  assert.deepEqual(JSON.parse(await request("/api/health")), {
    status: "ok",
    commit,
  });
});

test("home page renders", { timeout: 90_000 }, async () => {
  assert.match(await request("/"), /<title>helgef\u00f8lelse<\/title>/);
});
