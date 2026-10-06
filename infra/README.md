# Infrastructure

One Terraform configuration defines each environment from the beginning: its GCP project, billing linkage, private state bucket, API enablement, Artifact Registry, Cloud Run, service accounts, resource-scoped IAM, GitHub OIDC trust, GitHub Environment, `main` deployment policy, required reviewers for staging/production, and six deployment variables. Projects and state buckets do not need to exist beforehand, and there is no separate bootstrap module. Existing resources are adopted through imports instead of recreated.

The existing CD workflow still verifies and mirrors images, deploys candidates, tests them, and promotes traffic. Terraform ignores the Cloud Run image, container environment variables (including `GIT_SHA`), container name, revision name, traffic/tags, and deployment client metadata. It continues to own the runtime account, port, ingress, and public access. Public access uses Cloud Run's disabled invoker IAM check rather than requiring an `allUsers` IAM binding. Do not provision while CD is deploying to the same environment. Infrastructure changes can create revisions; inspect every plan before applying.

The registry configuration retains the existing 30-day cleanup rule and five-version keep rule, with cleanup in dry-run mode. Adopting Terraform does not activate image deletion. Workload identity resources use the project's numeric identifier to avoid replacement caused by project ID/number normalization during import.

## Inputs And Access

- Terraform 1.7 or newer, below 2.0. CI uses 1.9.8. Install it with the [official instructions](https://developer.hashicorp.com/terraform/install).
- A billing account ID. Terraform links each project to it; Google account signup, payment details, and creation of the billing account itself are outside Terraform's GCP provider.
- An authenticated provisioning identity authorized to create projects, link billing, enable APIs, and manage the infrastructure. For organization/folder projects this includes `roles/resourcemanager.projectCreator` on the parent and `roles/billing.user` on the billing account, plus permission to manage project billing and resources. An authorized human account can provision projects without an organization; service-account provisioning needs a suitable organization/folder. Terraform cannot grant its initial identity permissions it does not already have. This is not the narrowly scoped application deployer.
- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) application-default credentials: `gcloud auth application-default login`. No service account keys are needed.
- Repository admin access and `GITHUB_TOKEN` with permission to manage environments, deployment policies, and environment variables. A signed-in GitHub CLI can supply it with `export GITHUB_TOKEN="$(gh auth token)"`. Never put tokens in Terraform files or backend settings.

## Provision An Environment

Create `infra/dev.tfvars` using [environment.tfvars.example](environment.tfvars.example) as the template. Supply the desired project ID/name, billing account ID, environment, region, and repository settings. Use `organization_id` or `folder_id` if needed, not both. For adoption, match the existing project ID, display name, billing account, parent, and resource region to avoid unintended changes. Supply reviewer IDs for staging/production. Repeat with separate settings and state for each environment.

For a **new** environment, start with the default local backend (no local `backend_override.tf` file). The first apply creates all resources, including the private state bucket:

```sh
export ENV=dev
export TF_DATA_DIR="$PWD/infra/.terraform/$ENV"

terraform -chdir=infra init -backend-config="path=$PWD/infra/$ENV.tfstate"
terraform -chdir=infra plan -var-file="$ENV.tfvars" -out="$ENV.tfplan"
terraform -chdir=infra apply "$ENV.tfplan"
```

For an **existing** environment, initialize state as above, then follow [Adopt Existing Resources](#adopt-existing-resources) and [GitHub Configuration](#github-configuration) **before the first plan/apply**. Do not apply a creation plan against resources that already exist. If an environment already has Terraform state, keep using that state rather than initializing an empty replacement.

The project, service, accounts, registry, identity pool, and bucket have deletion protections. IAM resources are additive members rather than authoritative policies, preserving unrelated grants. Infrastructure still incurs GCP charges. After a new environment is provisioned, run the existing CD workflow to replace Google's temporary Cloud Run sample image with the verified application image.

## State Storage

Terraform initializes its backend **before** it can create resources. It therefore cannot create a nonexistent GCS backend bucket during that same initialization. Local state is the default, allowing the complete infrastructure to be created in one apply; keep an encrypted backup if you retain local state. This is a Terraform ordering constraint, not a requirement to provision a bucket manually.

For shared use, move the same state into the bucket Terraform just created. Read the bucket name while still using local state:

```sh
export STATE_BUCKET="$(terraform -chdir=infra output -raw state_bucket_name)"
```

Create the ignored `infra/backend_override.tf` with:

```hcl
terraform {
  backend "gcs" {}
}
```

It switches only the backend from local to GCS; all resources, including the bucket, remain in the same configuration. Then migrate the existing state:

```sh
terraform -chdir=infra init -migrate-state \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="prefix=helgefolelse/$ENV"
```

Confirm Terraform's state-copy prompt and verify `terraform -chdir=infra state list`. Keep the old local state backup until remote state is verified. For later commands, initialize with the same bucket/prefix but **without** `-migrate-state`. Each environment needs its own `TF_DATA_DIR`, variable file, and backend location. Never use state migration to switch between environments. For another fresh environment, temporarily remove the local backend override and repeat the initial local-state flow with its own data directory.

[backend.tfbackend.example](backend.tfbackend.example) shows equivalent GCS backend settings. GCS provides locking, and the private bucket has versioning and public-access prevention. Restrict access to infrastructure operators; backend operations require permission to read/write state and lock objects, such as bucket-scoped `roles/storage.objectAdmin`. The application deployer does not need state access. Commit provider lock files; local settings, backend overrides, plans, state, and caches are ignored by Git and excluded from the application image.

**Import before applying.** Create the ignored `infra/imports.tf` with import blocks for each existing project, application resource, and IAM grant that needs adoption. For example, the project import is:

```hcl
import {
  to = google_project.environment
  id = var.project_id
}
```

Add the other resources using their Terraform addresses and provider-specific import IDs. Imports are idempotent for resources already in state. Do not include an import for a resource or grant that does not exist; Terraform creates those instead. Import enabled APIs as needed without removing their definitions from the main configuration.

A `409 alreadyExists` error for the project means Terraform attempted creation because the existing project was not in state and no import was configured. Do not rename or delete the project. Configure its import and rerun the plan. A failed apply can still record other resources in state; inspect `terraform -chdir=infra state list` and keep using that same backend rather than starting empty state.

If the state bucket already exists and is not tracked in another state, import it too:

```sh
terraform -chdir=infra import -var-file="$ENV.tfvars" \
  google_storage_bucket.state "YOUR_STATE_BUCKET"
```

If you already applied the former separate bootstrap module, back up both states and transfer its resources into the initialized main **local** state instead of importing duplicate ownership:

```sh
terraform -chdir=infra state mv \
  -state="bootstrap/$ENV.tfstate" -state-out="$ENV.tfstate" \
  google_storage_bucket.state google_storage_bucket.state
terraform -chdir=infra state mv \
  -state="bootstrap/$ENV.tfstate" -state-out="$ENV.tfstate" \
  google_project_service.storage 'google_project_service.required["storage.googleapis.com"]'
```

These paths assume the former guide's local bootstrap state location. For remotely stored state, use Terraform's appropriate state-transfer procedure rather than these local-file flags. Never leave a resource owned by two states.

Adopt the existing GitHub settings below, then review and apply the combined plan:

```sh
terraform -chdir=infra plan -var-file="$ENV.tfvars" -out="$ENV.tfplan"
terraform -chdir=infra apply "$ENV.tfplan"
```

Review the plan: it should import existing resources without replacing the project, service, registry, accounts, or identity pool, and without reverting the deployed image or traffic. Verify the billing account, parent, display name, and GitHub protections. Stop if the plan shows unexpected billing changes, project moves, revisions, approval changes, or replacements. Imports can include configuration updates, not just state adoption. Once all environments are imported, remove the local import file.

Adopting Terraform does not remove obsolete preview infrastructure or IAM grants; clean those up separately after verifying they are unused.

## GitHub Configuration

GitHub environment management is enabled by default so new environments are fully defined in Terraform. Existing environments, deployment policies, and variables must be imported before applying. `terraform -chdir=infra output -json github_environment_variables` returns the six values used by the deployment workflow.

For staging/production, set `reviewer_user_ids` to the numeric GitHub IDs of the intended reviewers; empty lists are rejected. Find a user ID with `gh api users/USERNAME --jq .id`. Review the existing environment's reviewer and bypass settings before adopting it. This configuration supports user reviewers, not team reviewers, and uses GitHub's defaults for wait timers and bypass/self-review settings. Set `manage_github = false` only if intentionally leaving existing GitHub configuration unmanaged; its deployment variables must still match the Terraform outputs.

Import an existing environment and its `main` policy before planning:

```sh
terraform -chdir=infra import -var-file="$ENV.tfvars" \
  'github_repository_environment.web[0]' "helgefolelse:$ENV"
gh api "repos/FSH-LAB/helgefolelse/environments/$ENV/deployment-branch-policies"
terraform -chdir=infra import -var-file="$ENV.tfvars" \
  'github_repository_environment_deployment_policy.main[0]' "helgefolelse:$ENV:POLICY_ID"
```

Use the existing policy ID from the API response and adjust owner/repository names. If no policy exists, let Terraform create it. Inspect any additional branch/tag policies and remove unwanted ones separately; managing the `main` policy does not delete others.

For each existing variable, import with this pattern, replacing `VARIABLE_NAME` with each key from the Terraform output:

```sh
terraform -chdir=infra import -var-file="$ENV.tfvars" \
  'github_actions_environment_variable.deployment["VARIABLE_NAME"]' \
  "helgefolelse:$ENV:VARIABLE_NAME"
```

Then plan and apply as above. New environments need no imports. Do not later toggle GitHub management off to relinquish ownership: that plans resource deletion. Use Terraform's state-removal workflow deliberately instead.

## Routine Changes

Select the environment's existing state backend and data directory, then run `plan` and apply the reviewed saved plan. Terraform provisioning is intentionally not part of application deployments and does not get the application's OIDC deployer credentials. The provider only trusts the exact GitHub repository, `refs/heads/main`, and matching environment, and its deployer binding is environment-specific.

If a private GHCR package is used, its repository Actions access must also be granted through GitHub package settings.

## Infrastructure Delivery

[The infrastructure workflow](../.github/workflows/infrastructure.yml) is separate from application CD. It runs only on `main` and only after the repository variable `INFRA_CI_ENABLED` is explicitly set to `true`. Pull requests remain credential-free. Nothing in the workflow provisions an empty environment, migrates state, grants initial permissions, or enables its own automation.

### 1. Adopt And Verify Remote State

Complete imports and the GCS migration above for each environment before onboarding it. Keep the existing state; never initialize an empty replacement. Check the backend bucket/prefix and `terraform state list`, including the project, state bucket, and Cloud Run service. Pause application CD while performing operator provisioning or state migration. Routine CI refuses a backend missing these addresses.

Use `auto_create_network = false` for a new project. Match the recorded setting for an imported project: changing this creation-time setting can require replacement. The Trivy `GCP-0010` exception in [the scanner policy](../.trivyignore.yaml) expires on January 1, 2027. Audit inherited default networks/firewall rules before that date; disabling creation is not a cleanup of an existing network. Do not remove project deletion protection to satisfy a scanner.

### 2. Provision Dedicated Identities

Set `enable_infrastructure_ci = true` in the environment's operator variable file, then use an authorized operator to plan and apply against its existing state:

```sh
terraform -chdir=infra plan -var-file="$ENV.tfvars" -out="$ENV-ci.tfplan"
terraform -chdir=infra apply "$ENV-ci.tfplan"
```

Review the saved plan first. Expect two service accounts, a separate WIF provider, project-scoped roles, bucket-scoped object access, runtime-account impersonation for apply, and a seven-day lifecycle rule limited to `ci-plans/`. There must be no unexpected replacements or deletions. Both identities need state-object access because planning acquires a lock. This is sensitive access, not an untrusted-PR credential. The plan account otherwise receives read roles; the apply account receives resource-administration roles within this project, not Owner, Editor, billing-link, or project-creation permissions. IAM administration is powerful even when project-scoped: restrict who can edit the trusted workflow.

The WIF provider requires this repository, `main`, the exact infrastructure workflow path, and the corresponding infrastructure environment. The application deployer remains separate and gets no state access. Project creation/billing and initial trust remain controlled operator tasks.

### 3. Configure Operator-Owned GitHub Gates

With the correct environment backend still selected and a GitHub administrator authenticated, run from the repository root:

```sh
ENVIRONMENT="$ENV" bash infra/scripts/configure-infrastructure.sh
```

The helper reads applied Terraform outputs, copies the effective nonsecret configuration to `TF_VARS_JSON`, and configures `infra-plan-ENV` and `infra-ENV` with main-only deployment policies. It never enables repository automation. These approval environments deliberately live outside the state applied by routine CI, so that workflow cannot modify its own gates. The helper is operator-only and must not be called by a cloud-authenticated CI job.

Plan environments have no required reviewers. Apply environments require the Terraform-configured reviewer IDs; initial dev setup defaults to the authenticated administrator if its list is empty. Override with `REVIEWER_IDS='[12345,67890]'` when appropriate. Staging/production prevent self-review, and all infrastructure environments disable administrator bypass. Staging/production therefore need a reviewer other than the workflow initiator; a solo operator cannot independently approve their own production change.

Register a GitHub App, install it only on this repository, and grant **Administration: read** and **Variables: read**. In each infrastructure environment, set `TF_GITHUB_APP_ID` and the encrypted secret `TF_GITHUB_APP_PRIVATE_KEY`. Enter the private key directly through GitHub Settings or `gh secret set`; do not put it in Terraform inputs/state. The workflow mints short-lived, explicitly scoped installation tokens and revokes them on completion. It uses read-only GitHub tokens because routine changes to GitHub governance are policy-blocked.

The helper supplies these environment variables from Terraform outputs:

| Variable                                                | Purpose                                                  |
| ------------------------------------------------------- | -------------------------------------------------------- |
| `GCP_PROJECT_ID`, `GCP_REGION`, `CLOUD_RUN_SERVICE`     | Target project and application checks                    |
| `TF_STATE_BUCKET`, `TF_STATE_PREFIX`                    | Exact adopted GCS backend                                |
| `TF_WIF_PROVIDER`                                       | Dedicated infrastructure federation provider             |
| `TF_PLAN_SERVICE_ACCOUNT` or `TF_APPLY_SERVICE_ACCOUNT` | Environment-specific identity                            |
| `TF_VARS_JSON`                                          | Complete effective Terraform inputs, without credentials |

If inputs change, update both infrastructure environments consistently through the operator helper after applying the corresponding operator change. Plans bind to the inputs and refuse changed inputs at approval time. Do not place credentials in `TF_VARS_JSON`; adding future secret inputs requires a separate design.

Enable required code-owner review for `main`, require the existing CI verification checks, disallow direct pushes, and restrict bypass. [CODEOWNERS](../.github/CODEOWNERS) covers workflows, infrastructure, and scanner exceptions. An ownership file alone does not enforce approval.

### 4. Enable Manual Plan And Apply

Merge the reviewed implementation to `main` before using its cloud trust. Start with dev only:

```sh
gh variable set INFRA_CI_ENVIRONMENTS --repo FSH-LAB/helgefolelse --body '["dev"]'
gh variable set INFRA_DEV_AUTO_APPLY --repo FSH-LAB/helgefolelse --body false
gh variable set INFRA_CI_ENABLED --repo FSH-LAB/helgefolelse --body true
gh workflow run infrastructure.yml --ref main -f environment=dev -f operation=plan
```

After reviewing the dry-run summary, dispatch `operation=apply`. That run creates a **new** saved plan, then waits for the apply environment's approval. Review that run's summary before approving; approval never substitutes a different plan. A no-change plan skips apply. After successful dev testing, onboard staging/production and add them to `INFRA_CI_ENVIRONMENTS`, for example `["dev","staging","production"]`. Apply the same trusted configuration commit in order, generating a separate plan for each environment. This small-project workflow relies on the production reviewer to verify prior-environment results rather than introducing an additional promotion service.

Binary plans are stored only in the private state bucket under `ci-plans/ENV/RUN/ATTEMPT/SHA/`, not in GitHub artifacts. The apply job retrieves that run's saved plan and never generates a replacement before applying. Small `jq` checks use the plan's native timestamp and variables to enforce a four-hour expiry and matching environment inputs. Both jobs check out the same commit, use pinned Terraform and locked providers, and apply rejects a superseded main commit. No custom approval manifest or plan fingerprint is maintained. Treat bucket access as privileged: the saved-plan path is run-specific, but is not a signature or independent protection against a compromised identity with write access.

Terraform rejects saved plans invalidated by Terraform state changes. It does not detect every out-of-band cloud edit before applying. This lean pipeline intentionally removes the custom fresh-plan comparison; scheduled drift detection, short approval windows, and coordinated deployments reduce that risk but do not eliminate it. Investigate unexpected edits, then generate a new plan and obtain a new approval. A post-apply plan still checks convergence.

Terraform apply and application deploy use the same `deploy-web-ENV` concurrency group, with cancellation disabled. State locking remains enabled with a five-minute timeout. GitHub concurrency is mutual exclusion, not a FIFO queue: pending runs may be superseded. The main-commit and plan-expiry checks reject superseded or expired approvals. Operator commands outside Actions must also coordinate with deployments.

### 5. Policy Checks And Drift Detection

PR CI runs Terraform mock tests, executable plan-policy/runner tests, Trivy configuration scanning, workflow lint/security auditing, and existing application checks. Routine live plans block deletes/replacements, project/state-bucket/control-plane changes, all IAM changes, GitHub governance changes, and unsafe Cloud Run runtime-identity/protection changes. These changes use an operator-reviewed plan, not a broad CI bypass. Ordinary service/registry configuration remains eligible for the saved-plan path. Protection in policy complements `prevent_destroy`; removing a protected resource block can otherwise remove its Terraform lifecycle protection.

The daily scheduled workflow plans every onboarded environment using the read identity. It opens or updates one `Infrastructure drift: ENV` issue for configuration differences or failed checks, and closes it when a later plan is clean. It never applies or changes state to hide drift. Investigate whether a difference is an unauthorized cloud edit, a newly merged desired change, or an expected emergency change before deciding how to reconcile it. Terraform intentionally ignores CD-owned image/environment/revision/traffic fields, so those changes are outside this drift coverage.

### 6. Enable Automatic Dev Apply Last

After a successful manual dev apply, rerun the operator helper against dev with `DEV_AUTO_APPLY_READY=true` to remove only dev's reviewer gate, then enable the repository flag:

```sh
ENVIRONMENT=dev DEV_AUTO_APPLY_READY=true bash infra/scripts/configure-infrastructure.sh
gh variable set INFRA_DEV_AUTO_APPLY --repo FSH-LAB/helgefolelse --body true
```

Infrastructure-related pushes to `main` now plan and apply dev automatically when policies pass. Staging/production remain manual and approval-gated. Disable auto-dev with the same variable set to `false`; set `INFRA_CI_ENABLED=false` to pause the entire infrastructure workflow. Rerunning the helper normally reinstates dev's reviewer requirement.

### Recovery

If apply partially fails, preserve the same remote state and inspect actual resources using an authorized operator. Do not rerun an old binary plan or initialize new state. Generate a new plan after understanding the failure. Recover a state object from bucket version history only for verified state loss/corruption, not to undo cloud changes. Infrastructure rollback is a new reviewed configuration change; application rollback remains digest-based CD. Keep access to a separate recovery operator because CI cannot repair its own identity, WIF trust, or approval gates.

Sensitive Terraform output is captured on the ephemeral runner rather than printed publicly, and removed at job completion. Failed commands report the stage but omit provider details; reproduce with operator credentials in a private terminal. After apply, a clean plan verifies convergence and the existing smoke suite checks the currently deployed app commit, not the infrastructure commit. A smoke failure does not automatically undo infrastructure.

## Checks

These checks require no cloud credentials and never apply live infrastructure:

```sh
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra validate
terraform -chdir=infra test
```

Run them from a clean checkout, or use a separate copy of the tracked configuration for validation rather than the live environment's initialized backend. The ignored local `imports.tf` must not be present in the mock-test configuration: mock providers cannot execute real imports. A separate `TF_DATA_DIR` alone does not exclude import blocks. CI runs the same checks, including mocked plans for project/billing ownership, private state storage, parent validation, public access, cleanup safety, OIDC restrictions, deployment permissions, and required reviewers.
