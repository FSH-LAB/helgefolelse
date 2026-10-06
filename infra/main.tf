locals {
  repository = "${var.github_owner}/${var.github_repository}"
  services = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ])
  github_variables = {
    GCP_PROJECT_ID             = var.project_id
    GCP_REGION                 = var.region
    GAR_REPOSITORY             = google_artifact_registry_repository.web.repository_id
    CLOUD_RUN_SERVICE          = google_cloud_run_v2_service.web.name
    GCP_WIF_PROVIDER           = google_iam_workload_identity_pool_provider.github.name
    GCP_DEPLOY_SERVICE_ACCOUNT = google_service_account.deployer.email
  }
}

resource "google_project" "environment" {
  project_id      = var.project_id
  name            = coalesce(var.project_name, "Helgefolelse ${var.environment}")
  billing_account = var.billing_account_id
  org_id          = var.organization_id
  folder_id       = var.folder_id
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.organization_id == null || var.folder_id == null
      error_message = "Specify organization_id or folder_id, not both."
    }
  }
}

resource "google_project_service" "required" {
  for_each = local.services

  project            = google_project.environment.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_storage_bucket" "state" {
  project                     = google_project.environment.project_id
  name                        = coalesce(var.state_bucket_name, "${var.project_id}-terraform-state")
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.required]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_artifact_registry_repository" "web" {
  project       = google_project.environment.project_id
  location      = var.region
  repository_id = var.gar_repository
  format        = "DOCKER"
  description   = "Docker images for the Helgef\u00f8lelse web app."

  cleanup_policy_dry_run = true

  docker_config {
    immutable_tags = false
  }

  cleanup_policies {
    id     = "delete-web-after-30d"
    action = "DELETE"

    condition {
      tag_state             = "ANY"
      older_than            = "2592000s"
      package_name_prefixes = ["web"]
    }
  }

  cleanup_policies {
    id     = "keep-wep-latest-5"
    action = "KEEP"

    most_recent_versions {
      keep_count            = 5
      package_name_prefixes = ["web"]
    }
  }

  depends_on = [google_project_service.required]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "deployer" {
  project      = google_project.environment.project_id
  account_id   = "helgefolelse-deployer"
  display_name = "Helgefolelse GitHub deployer"

  depends_on = [google_project_service.required]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "runtime" {
  project      = google_project.environment.project_id
  account_id   = "helgefolelse-runtime"
  display_name = "Helgefolelse Cloud Run runtime"

  depends_on = [google_project_service.required]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_cloud_run_v2_service" "web" {
  project              = google_project.environment.project_id
  name                 = var.cloud_run_service
  location             = var.region
  deletion_protection  = true
  ingress              = "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled = true

  template {
    service_account = google_service_account.runtime.email

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      ports {
        container_port = 8080
      }
    }
  }

  depends_on = [google_project_service.required]

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      template[0].containers[0].image,
      template[0].containers[0].env,
      template[0].containers[0].name,
      template[0].revision,
      traffic,
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_v2_service_iam_member" "deployer" {
  project  = google_project.environment.project_id
  location = var.region
  name     = google_cloud_run_v2_service.web.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_artifact_registry_repository_iam_member" "deployer" {
  project    = google_project.environment.project_id
  location   = var.region
  repository = google_artifact_registry_repository.web.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_service_account_iam_member" "runtime_user" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = google_project.environment.number
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.required]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = google_project.environment.number
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "Helgefolelse ${var.environment} deployments"
  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.ref"         = "assertion.ref"
    "attribute.environment" = "assertion.environment"
  }
  attribute_condition = "assertion.repository == '${local.repository}' && assertion.ref == 'refs/heads/main' && assertion.environment == '${var.environment}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_deployer" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.environment/${var.environment}"
}

resource "github_repository_environment" "web" {
  count = var.manage_github ? 1 : 0

  repository  = var.github_repository
  environment = var.environment

  dynamic "reviewers" {
    for_each = var.environment == "dev" ? [] : [var.reviewer_user_ids]
    content {
      users = reviewers.value
    }
  }

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.environment == "dev" || length(var.reviewer_user_ids) > 0
      error_message = "Managed staging and production environments must have required reviewers."
    }
  }
}

resource "github_repository_environment_deployment_policy" "main" {
  count = var.manage_github ? 1 : 0

  repository     = var.github_repository
  environment    = github_repository_environment.web[0].environment
  branch_pattern = "main"
}

resource "github_actions_environment_variable" "deployment" {
  for_each = var.manage_github ? local.github_variables : {}

  repository    = var.github_repository
  environment   = github_repository_environment.web[0].environment
  variable_name = each.key
  value         = each.value
}