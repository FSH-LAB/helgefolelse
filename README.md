# Helgefolelse

A small website that shows how close it feels to the weekend. The reading rises from Monday to Friday at 16:00, stays at 100 through Saturday, and falls on Sunday. All times are interpreted in `Europe/Oslo`.

## Getting started

Install Node.js 24 or newer and enable pnpm through Corepack. The repository pins the pnpm version in `package.json`.

```sh
corepack enable pnpm
pnpm install
pnpm dev
```

Open [http://localhost:3000](http://localhost:3000). Run commands from the repository root unless noted otherwise.

## Commands

| Command                 | Purpose                           |
| ----------------------- | --------------------------------- |
| `pnpm dev`              | Start the development server      |
| `pnpm build`            | Build the web app for production  |
| `pnpm lint`             | Run ESLint                        |
| `pnpm lint:shell`       | Check deployment shell scripts    |
| `pnpm lint:workflows`   | Check GitHub Actions workflows    |
| `pnpm typecheck`        | Run TypeScript checks             |
| `pnpm test`             | Run app unit tests                |
| `pnpm format:check`     | Check formatting for CI           |
| `pnpm format`           | Format supported files            |
| `pnpm --filter web dev` | Run only the web app's dev script |

The root scripts use Turborepo to run tasks across workspaces. Currently there is one app, `web`; there are no shared packages or separate backend yet. For the local delivery lint commands on macOS, install the CLI tools with `brew install shellcheck actionlint`. CI installs a pinned actionlint version separately.

Smoke tests live in the web app and check a running server's health, commit SHA, and home page. They use Node's built-in test runner, so CI and deployment need no dependency install to run them:

```sh
SMOKE_URL=http://localhost:8080 SHA="$(git rev-parse HEAD)" pnpm --filter web test:smoke
```

Start the server or container with the same `GIT_SHA`. Unit tests run separately and do not require a server.

## Local image security scan

The delivery workflow scans the production image with Trivy before publishing it. To run the same scan locally on macOS, install [Trivy](https://trivy.dev/latest/getting-started/installation/) and make sure Docker is running:

```sh
brew install trivy
docker build --pull -f apps/web/Dockerfile -t helgefolelse-web:local .
trivy image \
	--scanners vuln,secret \
	--severity HIGH,CRITICAL \
	--ignore-unfixed \
	--exit-code 1 \
	helgefolelse-web:local
```

The command exits with status `1` when a HIGH or CRITICAL finding with an available fix is detected. Advisories without a published fix are reported but ignored, matching CI. Trivy downloads its vulnerability database on the first scan; use `trivy image --download-db-only` to update it separately.

## Delivery

The `CI/CD` workflow checks pull requests, merge-queue groups, and pushes to `main`. After a successful push-to-main verification, it builds and pushes one image to GHCR, scans that exact image digest with Trivy, and attests it before deploying to `dev`. Staging and production then promote the same verified digest; they do not rebuild it.

### Infrastructure

[Terraform configuration](infra/README.md) creates the GCP projects, links them to your billing account, and provisions private state buckets, application resources, IAM, and GitHub Environments and deployment variables. Use separate Terraform state per environment (`dev`, `staging`, `production`). There is one configuration and no separate bootstrap module. Existing resources are imported; new environments are provisioned from scratch.

Terraform owns infrastructure and IAM. The existing deployment workflow owns application images, revisions, and traffic, so infrastructure applies do not revert releases. CI validates Terraform and runs credential-free mock tests; it does not apply infrastructure changes.

### Publish and promote

On a push to `main`, the **CI/CD** workflow verifies the commit, builds and pushes one image to GHCR, scans the immutable image digest with Trivy, and creates a signed [build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations) only after the scan passes. It then promotes that same digest through `dev`, `staging`, and `production`. Staging and production wait for environment reviewers to approve. Pull requests and merge-queue groups run checks without publishing or deploying.

Every deployment first verifies the image's attestation (signed by `ci-cd.yml` on `main`) and that the image was built from the requested commit, then mirrors it to that environment's Artifact Registry. Cloud Run deploys the revision with zero traffic and a `candidate` tag; the workflow runs the app's smoke tests against that candidate and only shifts 100% of traffic after they pass. Failed tests leave existing service traffic unchanged. The GHCR image is then tagged with the environment name, so the package page shows what runs where. After production, the workflow creates a GitHub Release (`vYYYY.M.<run>`) with generated notes. The deployed service URL appears on its GitHub Environment. You can check a release yourself with `gh attestation verify oci://ghcr.io/<owner>/<repo>-web@<digest> --repo <owner>/<repo>`.

Only two workflows remain: CI/CD and reusable/manual deployment. Image vulnerability checks still gate PRs and releases; there is no scheduled rescan of already-deployed images. PR previews and canary rollouts are not configured. Shell scripts handle signed-release verification, digest-preserving registry mirroring, and Cloud Run operations. Deployment and promotion are separate script calls with the app's smoke tests between them; HTTP assertions belong to the app tests.

When migrating from the previous setup, remove unused `CANARY_PERCENT` and `CANARY_SECONDS` GitHub variables and the deployer's `roles/monitoring.viewer` grant. Remove existing preview Cloud Run tags/services, preview identities and their IAM grants, and the `preview` GitHub Environment if no longer used. The Terraform configuration restricts each WIF provider to its matching environment. Adopting Terraform or deleting workflows does not remove unmanaged cloud resources or existing previews.

To redeploy or roll back, open **Deploy web** in GitHub Actions on `main`, choose the environment, and enter either a commit SHA or a version tag (for example `v1.2.3`). The tag must point to a commit on `main` that CI has already published; the workflow resolves it to that commit's image, verifies its provenance, and deploys by digest. A version without the `v` prefix also resolves to a matching `v`-prefixed tag. To retry a failed automatic deployment after correcting IAM, use **Re-run failed jobs** on its CI run.

## Structure

- `apps/web/src/app/` - Next.js routes, layout, and the tide visualization.
- `apps/web/src/lib/` - the weekend calculation and display copy.
- `infra/` - Terraform projects, billing linkage, state storage, application infrastructure, migration examples, and mock tests.
- `pnpm-workspace.yaml` - workspace membership and dependency build settings.
- `turbo.json` - task orchestration and build caching.

This repository uses pnpm workspaces. Add app dependencies with `pnpm --filter web add <package>` and commit changes to `pnpm-lock.yaml`. Use pnpm rather than npm or Yarn so the lockfile stays consistent.
