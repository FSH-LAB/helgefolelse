import assert from "node:assert/strict";
import test from "node:test";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  cpSync,
  rmSync,
  existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

function runner() {
  const directory = mkdtempSync(join(tmpdir(), "infrastructure-test-"));
  mkdirSync(join(directory, "infra"));
  mkdirSync(join(directory, "bin"));
  mkdirSync(join(directory, "remote"));
  mkdirSync(join(directory, ".github/scripts"), { recursive: true });
  cpSync(
    new URL("infrastructure.sh", import.meta.url),
    join(directory, ".github/scripts/infrastructure.sh"),
  );
  mkdirSync(join(directory, "infra/scripts"));
  cpSync(
    new URL("../../infra/scripts/configure-infrastructure.sh", import.meta.url),
    join(directory, "infra/scripts/configure-infrastructure.sh"),
  );
  const tools = {
    terraform: `
      import { writeFileSync, readFileSync, existsSync, appendFileSync } from "node:fs";
      const command = process.argv[3];
      appendFileSync("commands", command + "\\n");
      if (command === "output") {
        console.log(JSON.stringify(process.argv.at(-1) === "infrastructure_ci" ? {
          state_bucket: "test-private-state", state_prefix: "helgefolelse/" + process.env.ENVIRONMENT,
          provider: "test-provider", plan_account: "plan@example.com", apply_account: "apply@example.com",
          inputs: { environment: process.env.ENVIRONMENT, enable_infrastructure_ci: true,
            reviewer_user_ids: [], github_owner: "owner", github_repository: "repository" }
        } : { GCP_PROJECT_ID: "test-project" }));
      } else if (command === "state") {
        if (!process.env.EMPTY_STATE) console.log("google_project.environment\\ngoogle_storage_bucket.state\\ngoogle_cloud_run_v2_service.web");
      } else if (command === "plan") {
        console.log("sensitive-terraform-value");
        if (process.argv.includes("-out=approved.tfplan")) writeFileSync("infra/approved.tfplan", JSON.stringify({
          timestamp: process.env.PLAN_TIMESTAMP || new Date().toISOString().slice(0, 19) + "Z",
          variables: Object.fromEntries(Object.entries(JSON.parse(process.env.TFVARS_JSON)).map(([key, value]) => [key, { value }])),
          resource_changes: [{ address: process.env.ADDRESS || "google_artifact_registry_repository.web", type: process.env.RESOURCE_TYPE || "google_artifact_registry_repository", mode: "managed", change: { actions: JSON.parse(process.env.ACTIONS || '["update"]'), before: {}, after: {} } }]
        }));
        process.exit(existsSync("infra/applied") ? 0 : 2);
      } else if (command === "show") {
        console.log(readFileSync("infra/approved.tfplan", "utf8"));
      } else if (command === "apply") {
        if (process.argv.at(-1) !== "approved.tfplan" || process.env.STALE_STATE) process.exit(1);
        writeFileSync("infra/applied", readFileSync("infra/approved.tfplan"));
      }
    `,
    gcloud: `
      import { cpSync } from "node:fs";
      import { basename } from "node:path";
      const sources = process.argv.slice(4, -2);
      for (const source of sources) {
        if (source.startsWith("gs://")) cpSync("remote/" + basename(source), "infra/" + basename(source));
        else cpSync(source, "remote/" + basename(source));
      }
    `,
    gh: `
      import { appendFileSync, readFileSync } from "node:fs";
      const args = process.argv.slice(2);
      if (args.includes("user")) console.log("12345");
      else if (args.includes("PUT")) appendFileSync("gates", readFileSync(0, "utf8"));
      else if (args.includes("--paginate")) console.log(JSON.stringify([{ branch_policies: process.env.UNEXPECTED_BRANCH ? [{name: "feature/*", type: "branch"}] : [] }]));
      else if (args[0] === "variable") appendFileSync("variables", args[2] + "\\n");
      else if (args.includes("POST")) console.log("{}");
      else console.log(process.env.NEW_MAIN || process.env.GITHUB_SHA);
    `,
  };
  for (const [name, source] of Object.entries(tools)) {
    writeFileSync(
      join(directory, "bin", name),
      `#!${process.execPath}\n${source}\n`,
      { mode: 0o700 },
    );
  }
  const env = {
    ...process.env,
    PATH: `${join(directory, "bin")}:${process.env.PATH}`,
    ENVIRONMENT: "dev",
    PROJECT_ID: "test-project",
    STATE_BUCKET: "test-private-state",
    STATE_PREFIX: "helgefolelse/dev",
    TFVARS_JSON: JSON.stringify({
      environment: "dev",
      project_id: "test-project",
      enable_infrastructure_ci: true,
    }),
    GITHUB_SHA: "a".repeat(40),
    GITHUB_RUN_ID: "123",
    GITHUB_RUN_ATTEMPT: "1",
    GITHUB_REPOSITORY: "owner/repository",
    GITHUB_OUTPUT: join(directory, "output"),
    GITHUB_STEP_SUMMARY: join(directory, "summary"),
  };
  return {
    directory,
    run(command, overrides = {}, script = "infrastructure.sh") {
      const path =
        script === "configure-infrastructure.sh"
          ? `infra/scripts/${script}`
          : `.github/scripts/${script}`;
      return spawnSync("bash", [path, command], {
        cwd: directory,
        env: { ...env, ...overrides },
        encoding: "utf8",
      });
    },
    cleanup() {
      rmSync(directory, { recursive: true, force: true });
    },
  };
}

test("runner saves and applies exact plan without exposing sensitive output", () => {
  const fixture = runner();
  try {
    const planned = fixture.run("plan");
    assert.equal(planned.status, 0, planned.stderr);
    assert.ok(existsSync(join(fixture.directory, "remote/approved.tfplan")));
    const savedPlan = readFileSync(
      join(fixture.directory, "remote/approved.tfplan"),
      "utf8",
    );
    assert.ok(!planned.stdout.includes("sensitive-terraform-value"));
    assert.ok(
      !readFileSync(join(fixture.directory, "summary"), "utf8").includes(
        "approved bytes",
      ),
    );
    const applied = fixture.run("apply");
    assert.equal(applied.status, 0, applied.stderr);
    assert.ok(existsSync(join(fixture.directory, "infra/applied")));
    assert.equal(
      readFileSync(join(fixture.directory, "infra/applied"), "utf8"),
      savedPlan,
    );
    const plans = readFileSync(join(fixture.directory, "commands"), "utf8")
      .split("\n")
      .filter((command) => command === "plan");
    assert.equal(plans.length, 2);
  } finally {
    fixture.cleanup();
  }
});

test("runner refuses empty state, mismatched environment, and malformed inputs", () => {
  const fixture = runner();
  try {
    for (const overrides of [
      { EMPTY_STATE: "true" },
      { STATE_PREFIX: "helgefolelse/production" },
      { TFVARS_JSON: "{}" },
    ]) {
      const result = fixture.run("plan", overrides);
      assert.notEqual(
        result.status,
        0,
        `${JSON.stringify(overrides)}: ${result.stderr}`,
      );
    }
    assert.ok(!existsSync(join(fixture.directory, "remote/approved.tfplan")));
  } finally {
    fixture.cleanup();
  }
});

test("runner refuses changed inputs, superseded commits, and stale-state apply failures", () => {
  const fixture = runner();
  try {
    assert.equal(fixture.run("plan").status, 0);
    for (const overrides of [
      {
        TFVARS_JSON: JSON.stringify({
          environment: "dev",
          project_id: "test-project",
          enable_infrastructure_ci: true,
          region: "changed",
        }),
      },
      { NEW_MAIN: "b".repeat(40) },
      { STALE_STATE: "true" },
    ]) {
      const result = fixture.run("apply", overrides);
      assert.notEqual(result.status, 0, result.stderr);
      assert.ok(!existsSync(join(fixture.directory, "infra/applied")));
    }
  } finally {
    fixture.cleanup();
  }
});

test("runner blocks destructive and operator-owned changes but reports drift", () => {
  const fixture = runner();
  try {
    for (const overrides of [
      { ACTIONS: '["delete","create"]' },
      ...[
        "google_project",
        "google_storage_bucket",
        "google_iam_workload_identity_pool_provider",
        "google_project_iam_member",
        "google_cloud_run_v2_service_iam_binding",
        "google_cloud_run_v2_service_iam_policy",
        "github_repository_environment",
        "google_cloud_run_v2_service",
      ].map((type) => ({ RESOURCE_TYPE: type })),
      {
        ADDRESS: 'google_service_account.infrastructure["apply"]',
        RESOURCE_TYPE: "google_service_account",
      },
    ]) {
      assert.notEqual(fixture.run("plan", overrides).status, 0);
    }
    const drift = fixture.run("drift", { RESOURCE_TYPE: "google_project" });
    assert.equal(drift.status, 0, drift.stderr);
    assert.ok(!existsSync(join(fixture.directory, "remote/approved.tfplan")));
  } finally {
    fixture.cleanup();
  }
});

test("runner reports no-op plans without marking them as changes", () => {
  const fixture = runner();
  try {
    const result = fixture.run("plan", {
      RESOURCE_TYPE: "google_project",
      ACTIONS: '["no-op"]',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(
      readFileSync(join(fixture.directory, "output"), "utf8"),
      /changed=false/,
    );
  } finally {
    fixture.cleanup();
  }
});

test("runner rejects expired, future, and malformed saved-plan timestamps", () => {
  const fixture = runner();
  try {
    for (const timestamp of [
      "2020-01-01T00:00:00Z",
      "2099-01-01T00:00:00Z",
      "invalid",
    ]) {
      assert.equal(
        fixture.run("plan", { PLAN_TIMESTAMP: timestamp }).status,
        0,
      );
      assert.notEqual(fixture.run("apply").status, 0);
      assert.ok(!existsSync(join(fixture.directory, "infra/applied")));
    }
  } finally {
    fixture.cleanup();
  }
});

test("operator onboarding starts dev with a reviewer and never enables automation", () => {
  const fixture = runner();
  try {
    const configured = fixture.run(
      "configure",
      {},
      "configure-infrastructure.sh",
    );
    assert.equal(configured.status, 0, configured.stderr);
    const gates = readFileSync(join(fixture.directory, "gates"), "utf8")
      .trim()
      .split("\n")
      .map(JSON.parse);
    assert.deepEqual(gates[0].reviewers, []);
    assert.deepEqual(gates[1].reviewers, [{ type: "User", id: 12345 }]);
    assert.equal(gates[1].can_admins_bypass, false);
    assert.ok(
      !readFileSync(join(fixture.directory, "variables"), "utf8").includes(
        "INFRA_CI_ENABLED",
      ),
    );
  } finally {
    fixture.cleanup();
  }
});

test("operator onboarding requires independent staging approval and rejects extra branches", () => {
  const fixture = runner();
  try {
    assert.notEqual(
      fixture.run(
        "configure",
        { ENVIRONMENT: "staging" },
        "configure-infrastructure.sh",
      ).status,
      0,
    );
    const configured = fixture.run(
      "configure",
      { ENVIRONMENT: "staging", REVIEWER_IDS: "[12345]" },
      "configure-infrastructure.sh",
    );
    assert.equal(configured.status, 0, configured.stderr);
    const gates = readFileSync(join(fixture.directory, "gates"), "utf8")
      .trim()
      .split("\n")
      .map(JSON.parse);
    assert.equal(gates[1].prevent_self_review, true);
    assert.equal(gates[1].can_admins_bypass, false);
    assert.notEqual(
      fixture.run(
        "configure",
        { UNEXPECTED_BRANCH: "true" },
        "configure-infrastructure.sh",
      ).status,
      0,
    );
  } finally {
    fixture.cleanup();
  }
});

test("operator onboarding can remove only dev reviewers for automatic apply", () => {
  const fixture = runner();
  try {
    assert.notEqual(
      fixture.run(
        "configure",
        { ENVIRONMENT: "production", DEV_AUTO_APPLY_READY: "true" },
        "configure-infrastructure.sh",
      ).status,
      0,
    );
    const configured = fixture.run(
      "configure",
      { DEV_AUTO_APPLY_READY: "true" },
      "configure-infrastructure.sh",
    );
    assert.equal(configured.status, 0, configured.stderr);
    const gates = readFileSync(join(fixture.directory, "gates"), "utf8")
      .trim()
      .split("\n")
      .map(JSON.parse);
    assert.deepEqual(gates[1].reviewers, []);
    assert.equal(gates[1].can_admins_bypass, false);
  } finally {
    fixture.cleanup();
  }
});
