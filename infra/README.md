# Infrastructure

The deployment workflows apply one Terraform configuration for each environment (`dev`, `staging`, `production`). A separate root manages GitHub environments and deployment variables.

All environments use `europe-north2`. The region is fixed in Terraform to match the deployment workflow and registry endpoint.

| Root            | Manages                                                                                       | State                                                               |
| --------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `infra/`        | GCP project, APIs, state bucket, Artifact Registry, Cloud Run, service accounts, IAM and OIDC | `gs://<project>-terraform-state/helgefolelse/<env>`                 |
| `infra/github/` | GitHub environments, reviewers, branch policy and deployment variables                        | `gs://generated-mote-510411-v8-terraform-state/helgefolelse/github` |

Terraform owns infrastructure; the deploy workflow owns the image, `GIT_SHA`, revisions and traffic. Those release fields are ignored by Terraform. CI cannot change project IAM, service accounts or OIDC trust, so those changes require an operator. Deletion protection is enabled on core resources.

## Manual GCP changes

Use this for changes the CI identity cannot apply. Authenticate with `gcloud auth application-default login`, choose an environment, and review the saved plan before applying. Do not run it while that environment is deploying.

```sh
ENV=dev # staging or production
PROJECT=$(sed -n 's/^project_id *= *"\(.*\)"/\1/p' "infra/environments/$ENV.tfvars")
export TF_DATA_DIR="$PWD/infra/.terraform/$ENV"

terraform -chdir=infra init -reconfigure \
  -backend-config="bucket=$PROJECT-terraform-state" \
  -backend-config="prefix=helgefolelse/$ENV"
terraform -chdir=infra plan \
  -var-file="environments/$ENV.tfvars" -out="$ENV.tfplan"
terraform -chdir=infra apply "$ENV.tfplan"
```

## Adopt an existing environment

Before enabling automated deploys, the environment's GCS state must track the existing project and application resources. Never let CI initialize an empty state for a project that already contains these resources. Run from the repository root with operator credentials. If local state already tracks the environment, use `-migrate-state` instead of `-reconfigure` and verify the remote state before continuing.

```sh
ENV=staging # or dev / production
PROJECT=hazel-core-510411-b1 # set the matching project ID
NUMBER=288502766582 # set the matching GCP project number
export TF_DATA_DIR="$PWD/infra/.terraform/gcp-$ENV"
terraform -chdir=infra init -reconfigure \
  -backend-config="bucket=$PROJECT-terraform-state" \
  -backend-config="prefix=helgefolelse/$ENV"

import_if_missing() {
  address="$1"
  id="$2"
  if ! terraform -chdir=infra state show "$address" >/dev/null 2>&1; then
    terraform -chdir=infra import -var-file="environments/$ENV.tfvars" "$address" "$id"
  fi
}

import_if_missing google_project.environment "$PROJECT"
for api in artifactregistry.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com run.googleapis.com storage.googleapis.com sts.googleapis.com; do
  if gcloud services list --enabled --project="$PROJECT" --format='value(config.name)' | grep -Fxq "$api"; then
    import_if_missing "google_project_service.required[\"$api\"]" "$PROJECT/$api"
  fi
done
import_if_missing google_storage_bucket.state "$PROJECT-terraform-state"
import_if_missing google_artifact_registry_repository.web "projects/$PROJECT/locations/europe-north2/repositories/helgefolelse"
import_if_missing google_service_account.deployer "projects/$PROJECT/serviceAccounts/helgefolelse-deployer@$PROJECT.iam.gserviceaccount.com"
import_if_missing google_service_account.runtime "projects/$PROJECT/serviceAccounts/helgefolelse-runtime@$PROJECT.iam.gserviceaccount.com"
import_if_missing google_cloud_run_v2_service.web "projects/$PROJECT/locations/europe-north2/services/helgefolelse-web"

POOL="projects/$NUMBER/locations/global/workloadIdentityPools/github-actions"
DEPLOYER="projects/$PROJECT/serviceAccounts/helgefolelse-deployer@$PROJECT.iam.gserviceaccount.com"
RUNTIME="projects/$PROJECT/serviceAccounts/helgefolelse-runtime@$PROJECT.iam.gserviceaccount.com"
import_if_missing google_iam_workload_identity_pool.github "$POOL"
import_if_missing google_iam_workload_identity_pool_provider.github "$POOL/providers/github"
import_if_missing google_service_account_iam_member.runtime_user \
  "$RUNTIME roles/iam.serviceAccountUser serviceAccount:helgefolelse-deployer@$PROJECT.iam.gserviceaccount.com"
import_if_missing google_service_account_iam_member.github_deployer \
  "$DEPLOYER roles/iam.workloadIdentityUser principalSet://iam.googleapis.com/$POOL/attribute.environment/$ENV"

terraform -chdir=infra state list
terraform -chdir=infra plan -var-file="environments/$ENV.tfvars" -out="$ENV.tfplan"
```

Review the plan. Existing core resources must not be created or replaced; expected changes may include missing enabled APIs and the deployer's project roles. Apply the saved plan only after review. Repeat for each environment, then allow CI to deploy. If an existing local state is migrated, preserve its backup until `terraform state list` confirms the GCS state is complete.

## Fresh project bootstrap

The GCS backend must exist before Terraform can initialize. For a fresh project in one of the three supported environment slots, create the project and state bucket once, then import them so Terraform can manage them:

```sh
ENV=dev # staging or production
PROJECT=your-project-id # also set this in infra/environments/$ENV.tfvars
PROJECT_NAME="Helgefolelse $ENV"
FOLDER_ID=your-folder-id
BILLING_ACCOUNT_ID=XXXXXX-XXXXXX-XXXXXX
REGION=europe-north2

gcloud projects create "$PROJECT" --name="$PROJECT_NAME" --folder="$FOLDER_ID"
gcloud billing projects link "$PROJECT" --billing-account="$BILLING_ACCOUNT_ID"
gcloud services enable storage.googleapis.com --project="$PROJECT"
gcloud storage buckets create "gs://$PROJECT-terraform-state" \
  --project="$PROJECT" --location="$REGION" \
  --uniform-bucket-level-access --public-access-prevention

export TF_DATA_DIR="$PWD/infra/.terraform/bootstrap-$ENV"
terraform -chdir=infra init \
  -backend-config="bucket=$PROJECT-terraform-state" \
  -backend-config="prefix=helgefolelse/$ENV"
terraform -chdir=infra import -var-file="environments/$ENV.tfvars" \
  google_project.environment "$PROJECT"
terraform -chdir=infra import -var-file="environments/$ENV.tfvars" \
  'google_project_service.required["storage.googleapis.com"]' "$PROJECT/storage.googleapis.com"
terraform -chdir=infra import -var-file="environments/$ENV.tfvars" \
  google_storage_bucket.state "$PROJECT-terraform-state"
terraform -chdir=infra plan -var-file="environments/$ENV.tfvars" -out="$ENV.tfplan"
terraform -chdir=infra apply "$ENV.tfplan"
```

Review the plan before applying. Then update that environment's project ID and number in `infra/github/main.tf` and apply the GitHub root. Existing environments should use their existing GCS state; do not bootstrap them as fresh projects.

## GitHub settings

CI cannot modify its own approval rules. To update GitHub environments or variables, use an administrator token and review the plan:

```sh
export TF_DATA_DIR="$PWD/infra/.terraform/github"
export GITHUB_TOKEN="$(gh auth token)"
terraform -chdir=infra/github init
terraform -chdir=infra/github plan
terraform -chdir=infra/github apply
```
