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
export GITHUB_TOKEN="$(gh auth token)"
terraform -chdir=infra/github init
terraform -chdir=infra/github plan
terraform -chdir=infra/github apply
```
