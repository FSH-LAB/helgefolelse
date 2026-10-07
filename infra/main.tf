locals {
  services = toset([
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])

  # The deploy workflow runs Terraform as this account. It deliberately cannot
  # change project IAM, service accounts or OIDC trust: those need an operator.
  deployer_roles = toset([
    "roles/viewer",
    "roles/iam.securityReviewer",
    "roles/iam.workloadIdentityPoolViewer",
    "roles/artifactregistry.admin",
    "roles/run.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/storage.admin",
  ])
}

resource "google_project" "environment" {
  project_id          = var.project_id
  name                = var.project_name
  folder_id           = var.folder_id
  billing_account     = var.billing_account_id
  auto_create_network = false
  deletion_policy     = "PREVENT"

  lifecycle {
    prevent_destroy = true
    # Billing is linked once by an operator; adopted projects keep their creation-time network setting.
    ignore_changes = [billing_account, auto_create_network]
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
  name                        = "${var.project_id}-terraform-state"
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
  repository_id = "helgefolelse"
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
    id     = "keep-web-latest-5"
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
  name                 = "helgefolelse-web"
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
    # Releases (image, GIT_SHA, revisions, traffic) are owned by the deploy workflow.
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

resource "google_project_iam_member" "deployer" {
  for_each = local.deployer_roles

  project = google_project.environment.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
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
  # GCP caps provider display names at 32 characters.
  display_name = "Helgefolelse ${var.environment == "production" ? "prod" : var.environment} deployments"
  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.ref"         = "assertion.ref"
    "attribute.environment" = "assertion.environment"
  }
  attribute_condition = "assertion.repository == '${var.github_repository}' && assertion.ref == 'refs/heads/main' && assertion.environment == '${var.environment}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_deployer" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.environment/${var.environment}"
}
