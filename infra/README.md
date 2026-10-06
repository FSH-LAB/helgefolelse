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

## Checks

These checks require no cloud credentials and never apply live infrastructure:

```sh
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra validate
terraform -chdir=infra test
```

Run them from a clean checkout, or use a separate copy of the tracked configuration for validation rather than the live environment's initialized backend. The ignored local `imports.tf` must not be present in the mock-test configuration: mock providers cannot execute real imports. A separate `TF_DATA_DIR` alone does not exclude import blocks. CI runs the same checks, including mocked plans for project/billing ownership, private state storage, parent validation, public access, cleanup safety, OIDC restrictions, deployment permissions, and required reviewers.
