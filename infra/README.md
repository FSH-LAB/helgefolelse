# Infrastructure

Two small Terraform roots:

| Root            | Manages                                                                                                     | Applied by                           | State                                                           |
| --------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------ | --------------------------------------------------------------- |
| `infra/`        | One GCP environment: project, APIs, state bucket, Artifact Registry, Cloud Run, service accounts, IAM, OIDC | The deploy workflow, on every deploy | `gs://<project>-terraform-state/helgefolelse/<env>`             |
| `infra/github/` | GitHub environments, required reviewers, `main`-only policy, deploy variables                               | An admin, locally (rare)             | `gs://<production project>-terraform-state/helgefolelse/github` |

Per-environment inputs live in [environments/](environments). The deploy workflow owns image, `GIT_SHA`, revisions and traffic; Terraform ignores them.

## How changes flow

A Terraform change is reviewed in a PR (CI runs `fmt`, `validate`, mock `test` and Trivy). After merge, each deploy job runs `terraform apply` for its environment before releasing the app, so the change reaches dev, then staging and production after their approvals. `prevent_destroy` stops deletion of the project, bucket, registry, accounts, service and identity pool.

The CI identity (`helgefolelse-deployer`) can change application infrastructure, but **cannot** change project IAM, service accounts or OIDC trust. Changes to those (or to the project itself) fail in CI by design and must be applied by an operator:

```sh
ENV=dev  # or staging / production
PROJECT=$(sed -n 's/^project_id *= *"\(.*\)"/\1/p' infra/environments/$ENV.tfvars)
export TF_DATA_DIR="$PWD/infra/.terraform/$ENV"
terraform -chdir=infra init -reconfigure \
  -backend-config="bucket=$PROJECT-terraform-state" -backend-config="prefix=helgefolelse/$ENV"
terraform -chdir=infra apply -var-file="environments/$ENV.tfvars"
```

Run this when no deploy is in progress. Use `gcloud auth application-default login` for credentials.

GitHub settings: `export GITHUB_TOKEN="$(gh auth token)"` then `terraform -chdir=infra/github init && terraform -chdir=infra/github apply`. CI never holds a token that can change its own approval gates.

## New environment

1. Add `environments/<env>.tfvars` and the environment to `local.environments` in [github/main.tf](github/main.tf).
2. Create the project and state bucket with temporary local state (Terraform cannot store state in a bucket it has not created yet):

   ```sh
   printf 'terraform {\n  backend "local" {}\n}\n' > infra/backend_override.tf
   terraform -chdir=infra init -reconfigure
   terraform -chdir=infra apply -var-file="environments/$ENV.tfvars" -var billing_account_id=XXXXXX-XXXXXX-XXXXXX
   rm infra/backend_override.tf
   terraform -chdir=infra init -migrate-state \
     -backend-config="bucket=$PROJECT-terraform-state" -backend-config="prefix=helgefolelse/$ENV"
   ```

3. Apply `infra/github`, then deploy.

## One-time migration from the previous setup

Do this before merging, with operator credentials. Nothing below deletes cloud resources.

1. **dev** (already in GCS state): stop managing GitHub from this root, then apply the new IAM model.

   ```sh
   # init as above with ENV=dev
   terraform -chdir=infra state rm github_repository_environment.web \
     github_repository_environment_deployment_policy.main github_actions_environment_variable.deployment
   terraform -chdir=infra apply -var-file=environments/dev.tfvars
   ```

   Expect: project IAM roles for the deployer added, its resource-scoped `run.developer`/`artifactregistry.writer` grants removed. Discard any `.terraform.lock.hcl` change caused by the old GitHub resources.

2. **staging** and **production** (not yet in Terraform): follow step 2 of [New environment](#new-environment) without `-var billing_account_id`, with the git-ignored `infra/imports.tf` present so existing resources are imported. Review the plan: no replacements, only the state bucket, two APIs and the deployer roles should be created.
3. **GitHub**: apply `infra/github` (its [imports.tf](github/imports.tf) adopts existing settings), then delete that file and the obsolete variables:

   ```sh
   for env in dev staging production; do
     for v in GCP_REGION GAR_REPOSITORY CLOUD_RUN_SERVICE; do gh variable delete "$v" --env "$env"; done
   done
   gh variable delete CANARY_PERCENT --env production && gh variable delete CANARY_SECONDS --env production
   ```

4. Delete `infra/imports.tf` and merge.
