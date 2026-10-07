# Infrastructure

The deployment workflows apply one Terraform configuration for each environment (`dev`, `staging`, `production`). A separate root manages GitHub environments and deployment variables.

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

## GitHub settings

CI cannot modify its own approval rules. To update GitHub environments or variables, use an administrator token and review the plan:

```sh
export GITHUB_TOKEN="$(gh auth token)"
terraform -chdir=infra/github init
terraform -chdir=infra/github plan
terraform -chdir=infra/github apply
```
