locals {
  infrastructure_roles = {
    plan = toset([
      "roles/viewer",
      "roles/iam.securityReviewer",
      "roles/iam.serviceAccountViewer",
      "roles/iam.workloadIdentityPoolViewer",
    ])
    apply = toset([
      "roles/viewer",
      "roles/run.admin",
      "roles/artifactregistry.admin",
      "roles/iam.serviceAccountAdmin",
      "roles/iam.workloadIdentityPoolAdmin",
      "roles/resourcemanager.projectIamAdmin",
      "roles/serviceusage.serviceUsageAdmin",
      "roles/storage.admin",
    ])
  }
  infrastructure_grants = merge([
    for identity, roles in local.infrastructure_roles : {
      for role in roles : "${identity}/${role}" => { identity = identity, role = role }
    }
  ]...)
}

resource "google_service_account" "infrastructure" {
  for_each = var.enable_infrastructure_ci ? local.infrastructure_roles : {}

  project      = google_project.environment.project_id
  account_id   = "helgefolelse-tf-${each.key}"
  display_name = "Helgefolelse Terraform ${each.key}"

  depends_on = [google_project_service.required]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_iam_member" "infrastructure" {
  for_each = var.enable_infrastructure_ci ? local.infrastructure_grants : {}

  project = google_project.environment.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.infrastructure[each.value.identity].email}"
}

resource "google_storage_bucket_iam_member" "infrastructure_state" {
  for_each = google_service_account.infrastructure

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${each.value.email}"
}

resource "google_service_account_iam_member" "infrastructure_runtime_user" {
  count = var.enable_infrastructure_ci ? 1 : 0

  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.infrastructure["apply"].email}"
}

resource "google_iam_workload_identity_pool_provider" "infrastructure" {
  count = var.enable_infrastructure_ci ? 1 : 0

  project                            = google_project.environment.number
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "infrastructure"
  display_name                       = "Terraform ${var.environment}"
  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.environment" = "assertion.environment"
  }
  attribute_condition = "assertion.repository == '${local.repository}' && assertion.ref == 'refs/heads/main' && assertion.workflow_ref == '${local.repository}/.github/workflows/infrastructure.yml@refs/heads/main' && assertion.environment in ['infra-plan-${var.environment}', 'infra-${var.environment}']"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "infrastructure_federation" {
  for_each = google_service_account.infrastructure

  service_account_id = each.value.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.environment/${each.key == "plan" ? "infra-plan" : "infra"}-${var.environment}"
}