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

## Provision a supported environment

Only `dev`, `staging`, and `production` are supported. This procedure provisions a fresh project for one of those environment slots; it does not add a fourth environment. Adding another requires updating the environment validation, workflow choices, GitHub environment map, and OIDC trust first.

1. Choose one supported environment slot and set its project ID and name in `environments/<env>.tfvars`.
2. Create the project and state bucket with temporary local state (Terraform cannot store state in a bucket it has not created yet):

   ```sh

   ```

ENV=staging # dev, staging, or production
PROJECT=your-new-project-id
export TF_DATA_DIR="$PWD/infra/.terraform/$ENV"
printf 'terraform {\n backend "local" {}\n}\n' > infra/backend_override.tf
terraform -chdir=infra init -reconfigure -backend-config="path=$ENV.tfstate"
terraform -chdir=infra apply -var-file="environments/$ENV.tfvars" -var billing_account_id=XXXXXX-XXXXXX-XXXXXX
rm infra/backend_override.tf
terraform -chdir=infra init -migrate-state \
-backend-config="bucket=$PROJECT-terraform-state" -backend-config="prefix=helgefolelse/$ENV"

````

3. Update the project ID and the number from `gcloud projects describe "$PROJECT" --format='value(projectNumber)'` in `infra/github/main.tf`, apply `infra/github`, then deploy.

## One-time migration from the previous setup

Do this before merging, with operator credentials. Nothing below deletes cloud resources.

1. **dev** (already in GCS state): stop managing GitHub from this root, then apply the new IAM model.

```sh
# init as above with ENV=dev
terraform -chdir=infra state rm github_repository_environment.web \
  github_repository_environment_deployment_policy.main github_actions_environment_variable.deployment
terraform -chdir=infra apply -var-file=environments/dev.tfvars
````

Expect: project IAM roles for the deployer added, its resource-scoped `run.developer`/`artifactregistry.writer` grants removed. Discard any `.terraform.lock.hcl` change caused by the old GitHub resources.

2. **staging** and **production**: for each environment, use a separate empty local state, import the existing resources below, review the plan, apply it, then migrate that state to GCS. Do not import an address already present in state. The project numbers are staging `288502766582` and production `423756211110`.

   ```sh
   cd infra
   ENV=staging # repeat with production
   PROJECT=hazel-core-510411-b1 # production: generated-mote-510411-v8
   NUMBER=288502766582 # production: 423756211110
   export TF_DATA_DIR="$PWD/.terraform/$ENV"
   printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
   terraform init -reconfigure -backend-config="path=$ENV.tfstate"

   terraform import -var-file="environments/$ENV.tfvars" google_project.environment "$PROJECT"
   for api in artifactregistry.googleapis.com iam.googleapis.com iamcredentials.googleapis.com run.googleapis.com sts.googleapis.com; do
     terraform import -var-file="environments/$ENV.tfvars" "google_project_service.required[\"$api\"]" "$PROJECT/$api"
   done
   terraform import -var-file="environments/$ENV.tfvars" google_storage_bucket.state "$PROJECT-terraform-state"
   terraform import -var-file="environments/$ENV.tfvars" google_artifact_registry_repository.web "projects/$PROJECT/locations/europe-north2/repositories/helgefolelse"
   terraform import -var-file="environments/$ENV.tfvars" google_service_account.deployer "projects/$PROJECT/serviceAccounts/helgefolelse-deployer@$PROJECT.iam.gserviceaccount.com"
   terraform import -var-file="environments/$ENV.tfvars" google_service_account.runtime "projects/$PROJECT/serviceAccounts/helgefolelse-runtime@$PROJECT.iam.gserviceaccount.com"
   terraform import -var-file="environments/$ENV.tfvars" google_cloud_run_v2_service.web "projects/$PROJECT/locations/europe-north2/services/helgefolelse-web"

   POOL="projects/$NUMBER/locations/global/workloadIdentityPools/github-actions"
   terraform import -var-file="environments/$ENV.tfvars" google_iam_workload_identity_pool.github "$POOL"
   terraform import -var-file="environments/$ENV.tfvars" google_iam_workload_identity_pool_provider.github "$POOL/providers/github"
   terraform import -var-file="environments/$ENV.tfvars" google_service_account_iam_member.runtime_user \
     "projects/$PROJECT/serviceAccounts/helgefolelse-runtime@$PROJECT.iam.gserviceaccount.com roles/iam.serviceAccountUser serviceAccount:helgefolelse-deployer@$PROJECT.iam.gserviceaccount.com"
   terraform import -var-file="environments/$ENV.tfvars" google_service_account_iam_member.github_deployer \
     "projects/$PROJECT/serviceAccounts/helgefolelse-deployer@$PROJECT.iam.gserviceaccount.com roles/iam.workloadIdentityUser principalSet://iam.googleapis.com/$POOL/attribute.environment/$ENV"

   terraform plan -var-file="environments/$ENV.tfvars" -out="$ENV.tfplan"
   # Confirm no replacements or destroys before applying.
   terraform apply "$ENV.tfplan"
   rm backend_override.tf
   terraform init -migrate-state -backend-config="bucket=$PROJECT-terraform-state" -backend-config="prefix=helgefolelse/$ENV"
   ```

   The plan should create the two remaining APIs and deployer project roles; the existing state bucket and application resources should be imported. Existing resource-scoped deployer grants are not in this configuration and remain in GCP; remove them separately only after confirming the new project roles work.

3. **GitHub**: import the existing environments, branch policies, and the three variables this config manages before applying:

   ```sh
   export GITHUB_TOKEN="$(gh auth token)"
   terraform -chdir=infra/github init
   for env in dev staging production; do
     terraform -chdir=infra/github import "github_repository_environment.env[\"$env\"]" "helgefolelse:$env"
     policy_id="$(gh api "repos/FSH-LAB/helgefolelse/environments/$env/deployment-branch-policies" --jq '.branch_policies[] | select(.name == "main" and .type == "branch") | .id')"
     terraform -chdir=infra/github import "github_repository_environment_deployment_policy.main[\"$env\"]" "helgefolelse:$env:$policy_id"
     for name in GCP_PROJECT_ID GCP_WIF_PROVIDER GCP_DEPLOY_SERVICE_ACCOUNT; do
       terraform -chdir=infra/github import "github_actions_environment_variable.env[\"$env/$name\"]" "helgefolelse:$env:$name"
     done
   done
   terraform -chdir=infra/github plan
   # Confirm no unexpected creates or changes before applying.
   terraform -chdir=infra/github apply
   ```

   Then delete the obsolete variables:

   ```sh
   for env in dev staging production; do
     for v in GCP_REGION GAR_REPOSITORY CLOUD_RUN_SERVICE; do gh variable delete "$v" --env "$env"; done
   done
   gh variable delete CANARY_PERCENT --env production && gh variable delete CANARY_SECONDS --env production
   ```

4. Merge after both roots have clean plans. No temporary import files are needed.
