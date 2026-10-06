output "github_environment_variables" {
  description = "Environment variables consumed by the existing deployment workflow."
  value       = local.github_variables
}

output "service_url" {
  value = google_cloud_run_v2_service.web.uri
}

output "state_bucket_name" {
  description = "Bucket created by this configuration for optional GCS state migration."
  value       = google_storage_bucket.state.name
}

output "infrastructure_ci" {
  description = "Operator-configured infrastructure environment variables; do not let routine CI manage its own approval environments."
  value = var.enable_infrastructure_ci ? {
    project_id    = google_project.environment.project_id
    state_bucket  = google_storage_bucket.state.name
    state_prefix  = "helgefolelse/${var.environment}"
    provider      = google_iam_workload_identity_pool_provider.infrastructure[0].name
    plan_account  = google_service_account.infrastructure["plan"].email
    apply_account = google_service_account.infrastructure["apply"].email
    inputs = {
      project_id               = var.project_id
      project_name             = var.project_name
      auto_create_network      = var.auto_create_network
      billing_account_id       = var.billing_account_id
      organization_id          = var.organization_id
      folder_id                = var.folder_id
      state_bucket_name        = var.state_bucket_name
      environment              = var.environment
      region                   = var.region
      gar_repository           = var.gar_repository
      cloud_run_service        = var.cloud_run_service
      github_owner             = var.github_owner
      github_repository        = var.github_repository
      manage_github            = var.manage_github
      reviewer_user_ids        = var.reviewer_user_ids
      enable_infrastructure_ci = var.enable_infrastructure_ci
    }
  } : null
  sensitive = true
}