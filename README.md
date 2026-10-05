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
| `pnpm format:check`     | Check formatting for CI           |
| `pnpm format`           | Format supported files            |
| `pnpm --filter web dev` | Run only the web app's dev script |

The root scripts use Turborepo to run tasks across workspaces. Currently there is one app, `web`; there are no shared packages or separate backend yet. For the local delivery lint commands on macOS, install the CLI tools with `brew install shellcheck actionlint`. CI installs a pinned actionlint version separately.

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

The `CI/CD` workflow checks pull requests, merge-queue groups, and pushes to `main`. After a successful push-to-main verification, it builds and pushes one image to GHCR, scans that exact image digest with Trivy, and attests it before deploying to `dev`. Staging and production then promote the same verified digest; they do not rebuild it. Set up each environment in its own Google Cloud project; you need a Google Cloud account authorized to enable APIs, create resources, and manage IAM, plus repository admin access on GitHub. Install and sign in to the [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud auth login`) and [GitHub CLI](https://cli.github.com/) (`gh auth login`). Enable billing on each project before provisioning Cloud Run.

### 1. Provision each Google Cloud project

In [Google Cloud Console](https://console.cloud.google.com/projectcreate), create one project for each environment (`dev`, `staging`, `production`) and link each project to a billing account under **Billing**. If your organization requires projects in a particular folder or organization, select it during creation. Use the three different project IDs below, and run the remaining commands once per environment; adjust the region and names as needed. The GitHub repository name must match its current owner exactly.

```sh
export ENV=dev
export PROJECT_ID=your-dev-project-id
export REGION=europe-north1
export GAR_REPOSITORY=helgefolelse
export CLOUD_RUN_SERVICE=helgefolelse-web
export REPO=FSH-LAB/helgefolelse
export DEPLOY_EMAIL="helgefolelse-deployer@$PROJECT_ID.iam.gserviceaccount.com"
export RUNTIME_EMAIL="helgefolelse-runtime@$PROJECT_ID.iam.gserviceaccount.com"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

gcloud services enable iam.googleapis.com iamcredentials.googleapis.com \
	sts.googleapis.com artifactregistry.googleapis.com run.googleapis.com \
	monitoring.googleapis.com --project="$PROJECT_ID"
gcloud artifacts repositories create "$GAR_REPOSITORY" \
	--repository-format=docker --location="$REGION" --project="$PROJECT_ID"
gcloud iam service-accounts create helgefolelse-deployer --project="$PROJECT_ID"
gcloud iam service-accounts create helgefolelse-runtime --project="$PROJECT_ID"
```

Bootstrap the public Cloud Run service with a temporary Google sample image. CD deploys the published web image as a zero-traffic `candidate` revision, checks `/api/health` against its commit SHA, and only then shifts service traffic to it. The application serves on port 8080.

```sh
gcloud run deploy "$CLOUD_RUN_SERVICE" \
	--image=us-docker.pkg.dev/cloudrun/container/hello \
	--service-account="$RUNTIME_EMAIL" --port=8080 --allow-unauthenticated \
	--region="$REGION" --project="$PROJECT_ID"
gcloud artifacts repositories add-iam-policy-binding "$GAR_REPOSITORY" \
	--location="$REGION" --project="$PROJECT_ID" \
	--member="serviceAccount:$DEPLOY_EMAIL" --role=roles/artifactregistry.writer
gcloud run services add-iam-policy-binding "$CLOUD_RUN_SERVICE" \
	--region="$REGION" --project="$PROJECT_ID" \
	--member="serviceAccount:$DEPLOY_EMAIL" --role=roles/run.developer
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_EMAIL" \
	--project="$PROJECT_ID" --member="serviceAccount:$DEPLOY_EMAIL" \
	--role=roles/iam.serviceAccountUser
# Lets the canary read the candidate revision's 5xx count.
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
	--member="serviceAccount:$DEPLOY_EMAIL" --role=roles/monitoring.viewer --condition=None
```

### 2. Trust GitHub Actions without a key

Create a Workload Identity Pool and OIDC provider in **each** project. The provider only accepts tokens from this repository, the `main` branch, and the matching GitHub Environment. Bind the deploy service account to that **environment** principal, so a token for one environment (for example `preview`) can never impersonate another environment's deployer.

```sh
gcloud iam workload-identity-pools create github-actions \
	--location=global --project="$PROJECT_ID" --display-name='GitHub Actions'
gcloud iam workload-identity-pools providers create-oidc github \
	--location=global --project="$PROJECT_ID" --workload-identity-pool=github-actions \
	--issuer-uri=https://token.actions.githubusercontent.com \
	--attribute-mapping='google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.environment=assertion.environment' \
	--attribute-condition="assertion.repository == '$REPO' && assertion.ref == 'refs/heads/main' && assertion.environment == '$ENV'"
gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_EMAIL" \
	--project="$PROJECT_ID" --role=roles/iam.workloadIdentityUser \
	--member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions/attribute.environment/$ENV"
```

The provider resource name for this environment is `projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions/providers/github` (replace `PROJECT_NUMBER` with the value above). Do not create or store a service account key in GitHub. When changing the repository owner, update the provider condition; the environment binding does not change.

Verify both sides of the trust relationship before deploying:

```sh
gcloud iam workload-identity-pools providers describe github \
	--location=global --project="$PROJECT_ID" --workload-identity-pool=github-actions \
	--format='yaml(name,attributeCondition,attributeMapping)'
gcloud iam service-accounts get-iam-policy "$DEPLOY_EMAIL" \
	--project="$PROJECT_ID" --format='yaml(bindings)'
```

The second command must show `roles/iam.workloadIdentityUser` granted to the `attribute.environment/$ENV` principal set. A missing provider variable in GitHub causes an auth input error; an OIDC attribute-condition error means the provider rejected the GitHub token; `iam.serviceAccounts.getAccessToken` denied means the accepted token cannot impersonate the deployment service account. IAM changes can take a few minutes to propagate; use a fresh CD authentication attempt to verify them.

### 3. Configure GitHub Environments

Under repository **Settings > Environments**, create `dev`, `staging`, and `production`. Restrict deployments to `main`; require reviewers for `staging` and `production`. Add these **environment variables** to each environment (not environment secrets or repository variables), using the values from that environment's project:

| Variable                     | Value                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------ |
| `GCP_PROJECT_ID`             | `$PROJECT_ID`                                                                                    |
| `GCP_REGION`                 | `$REGION`                                                                                        |
| `GAR_REPOSITORY`             | `$GAR_REPOSITORY`                                                                                |
| `CLOUD_RUN_SERVICE`          | `$CLOUD_RUN_SERVICE`                                                                             |
| `GCP_WIF_PROVIDER`           | `projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions/providers/github` |
| `GCP_DEPLOY_SERVICE_ACCOUNT` | `$DEPLOY_EMAIL`                                                                                  |

Replace shell variable names in the table with their actual values when entering them in GitHub. If the GHCR image is private, grant this repository's Actions read access to its package under the package's settings.

To roll production out gradually, also set these optional variables on that environment. The candidate gets `CANARY_PERCENT` of traffic for `CANARY_SECONDS`; any 5xx response from it in Cloud Monitoring, or any failure or cancellation during the window, moves traffic back to the previous revision. Cloud Run metrics arrive up to about three minutes late, so keep the window well above 180 seconds.

| Variable         | Example | Purpose                                      |
| ---------------- | ------- | -------------------------------------------- |
| `CANARY_PERCENT` | `10`    | Share of traffic for the candidate (1-99)    |
| `CANARY_SECONDS` | `600`   | Observation window before 100% (default 300) |

### 4. Optional: pull request previews

The **Preview** workflow deploys each pull request from this repository as a zero-traffic `pr-<number>` revision and shows its URL on the PR; closing the PR removes the tag. Forks and Dependabot PRs are skipped. Previews run untrusted branch code, so give them their own Cloud Run service and deployer in the `dev` project. With the step 1 variables still set for `dev`:

```sh
export PREVIEW_SERVICE=helgefolelse-preview
export PREVIEW_EMAIL="helgefolelse-previewer@$PROJECT_ID.iam.gserviceaccount.com"
export PREVIEW_RUNTIME_EMAIL="helgefolelse-preview-runtime@$PROJECT_ID.iam.gserviceaccount.com"

gcloud iam service-accounts create helgefolelse-previewer --project="$PROJECT_ID"
gcloud iam service-accounts create helgefolelse-preview-runtime --project="$PROJECT_ID"
gcloud run deploy "$PREVIEW_SERVICE" \
	--image=us-docker.pkg.dev/cloudrun/container/hello \
	--service-account="$PREVIEW_RUNTIME_EMAIL" --port=8080 --allow-unauthenticated \
	--max-instances=1 --region="$REGION" --project="$PROJECT_ID"
gcloud run services add-iam-policy-binding "$PREVIEW_SERVICE" \
	--region="$REGION" --project="$PROJECT_ID" \
	--member="serviceAccount:$PREVIEW_EMAIL" --role=roles/run.developer
gcloud artifacts repositories add-iam-policy-binding "$GAR_REPOSITORY" \
	--location="$REGION" --project="$PROJECT_ID" \
	--member="serviceAccount:$PREVIEW_EMAIL" --role=roles/artifactregistry.writer
gcloud iam service-accounts add-iam-policy-binding "$PREVIEW_RUNTIME_EMAIL" \
	--project="$PROJECT_ID" --member="serviceAccount:$PREVIEW_EMAIL" \
	--role=roles/iam.serviceAccountUser
gcloud iam service-accounts add-iam-policy-binding "$PREVIEW_EMAIL" \
	--project="$PROJECT_ID" --role=roles/iam.workloadIdentityUser \
	--member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions/attribute.environment/preview"
```

PR runs use a `refs/pull/<number>/merge` ref, so allow the `preview` environment from any ref while keeping `dev` on `main`:

```sh
gcloud iam workload-identity-pools providers update-oidc github \
	--location=global --project="$PROJECT_ID" --workload-identity-pool=github-actions \
	--attribute-condition="assertion.repository == '$REPO' && ((assertion.ref == 'refs/heads/main' && assertion.environment == 'dev') || assertion.environment == 'preview')"
```

Finally, create a `preview` GitHub Environment **without** a branch restriction or reviewers, and give it the step 3 variables with `CLOUD_RUN_SERVICE` set to `$PREVIEW_SERVICE` and `GCP_DEPLOY_SERVICE_ACCOUNT` set to `$PREVIEW_EMAIL`. Until it exists, the Preview workflow fails without affecting CI or deployments.

### 5. Publish and promote

On a push to `main`, the **CI/CD** workflow verifies the commit, builds and pushes one image to GHCR, scans the immutable image digest with Trivy, and creates a signed [build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations) only after the scan passes. It then promotes that same digest through `dev`, `staging`, and `production`. Staging and production wait for environment reviewers to approve. Pull requests and merge-queue groups run checks without publishing or deploying.

Every deployment first verifies the image's attestation (signed by `ci-cd.yml` on `main`) and that the image was built from the requested commit, then mirrors it to that environment's Artifact Registry. Cloud Run deploys the revision with zero traffic and a `candidate` tag; the workflow checks that its `/api/health` response reports the expected commit SHA and that the home page renders, optionally runs the canary described above, and then shifts 100% of traffic to it. The GHCR image is then tagged with the environment name, so the package page shows what runs where. After production, the workflow creates a GitHub Release (`vYYYY.M.<run>`) with generated notes. The deployed service URL appears on its GitHub Environment. You can check a release yourself with `gh attestation verify oci://ghcr.io/<owner>/<repo>-web@<digest> --repo <owner>/<repo>`.

To redeploy or roll back, open **Deploy web** in GitHub Actions on `main`, choose the environment, and enter either a commit SHA or a version tag (for example `v1.2.3`). The tag must point to a commit on `main` that CI has already published; the workflow resolves it to that commit's image, verifies its provenance, and deploys by digest. A version without the `v` prefix also resolves to a matching `v`-prefixed tag. To retry a failed automatic deployment after correcting IAM, use **Re-run failed jobs** on its CI run.

## Structure

- `apps/web/src/app/` - Next.js routes, layout, and the tide visualization.
- `apps/web/src/lib/` - the weekend calculation and display copy.
- `pnpm-workspace.yaml` - workspace membership and dependency build settings.
- `turbo.json` - task orchestration and build caching.

This repository uses pnpm workspaces. Add app dependencies with `pnpm --filter web add <package>` and commit changes to `pnpm-lock.yaml`. Use pnpm rather than npm or Yarn so the lockfile stays consistent.
