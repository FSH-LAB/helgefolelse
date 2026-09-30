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
| `pnpm typecheck`        | Run TypeScript checks             |
| `pnpm format:check`     | Check formatting for CI           |
| `pnpm format`           | Format supported files            |
| `pnpm --filter web dev` | Run only the web app's dev script |

The root scripts use Turborepo to run tasks across workspaces. Currently there is one app, `web`; there are no shared packages or separate backend yet.

## Delivery

CI checks PRs and pushes to `main`. After a successful push-to-main CI run, the image workflow builds the web image, blocks publication on high or critical Trivy findings, tags it with the commit SHA, and pushes it to GHCR. The same image digest is then mirrored to Google Artifact Registry and deployed to the `dev` Cloud Run service. CI and infrastructure provisioning are separate from application deployment.

Create GitHub Environments named `dev`, `staging`, and `production` under repository Settings. Allow deployments only from `main`; deploy to `dev` automatically, and require reviewers for `staging` and `production`. Add these **environment variables** to each environment (they are identifiers, not credentials):

| Variable                     | Value                                                               |
| ---------------------------- | ------------------------------------------------------------------- |
| `GCP_PROJECT_ID`             | The GCP project for this environment                                |
| `GCP_REGION`                 | Cloud Run and Artifact Registry region, for example `europe-north1` |
| `GAR_REPOSITORY`             | Existing Docker-format Artifact Registry repository name            |
| `CLOUD_RUN_SERVICE`          | Existing Cloud Run service name                                     |
| `GCP_WIF_PROVIDER`           | Full Workload Identity Federation provider resource name            |
| `GCP_DEPLOY_SERVICE_ACCOUNT` | Deployment service account email in this GCP project                |

Use a separate GCP project and deployment service account per environment. Provision the Artifact Registry repository and public Cloud Run service (port 8080, `/api/health` for health checks) outside the application workflow. Grant the deployment account only Artifact Registry Writer on its repository, Cloud Run Developer on its service, and Service Account User on the service's runtime identity. Configure GitHub OIDC Workload Identity Federation with `roles/iam.workloadIdentityUser` on the deployment account; restrict provider trust to this repository, the `main` ref, and the matching GitHub Environment. Do not store service account keys in GitHub. For private GHCR images, grant this repository's Actions read access to the package if it is not already linked.

To promote to `staging` or `production`, run **Deploy web** from the Actions tab on `main`. Select the environment and enter the full commit SHA and `sha256:` GHCR digest from the successful **Publish web image** run summary. The deploy workflow verifies the commit and image label, mirrors that exact image to the selected project's Artifact Registry, deploys by the resulting registry digest, and checks `/api/health`. No image is rebuilt for promotion. Keep the prior Cloud Run revision available for rollback.

## Structure

- `apps/web/src/app/` - Next.js routes, layout, and the tide visualization.
- `apps/web/src/lib/` - the weekend calculation and display copy.
- `pnpm-workspace.yaml` - workspace membership and dependency build settings.
- `turbo.json` - task orchestration and build caching.

This repository uses pnpm workspaces. Add app dependencies with `pnpm --filter web add <package>` and commit changes to `pnpm-lock.yaml`. Use pnpm rather than npm or Yarn so the lockfile stays consistent.
