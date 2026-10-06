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