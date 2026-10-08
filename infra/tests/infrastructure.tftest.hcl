mock_provider "google" {
  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/123456789/locations/global/workloadIdentityPools/github-actions"
    }
  }
}

variables {
  environment  = "dev"
  project_id   = "test-project"
  project_name = "Test"
}

run "protects_core_resources" {
  command = plan

  assert {
    condition     = google_project.environment.deletion_policy == "PREVENT" && !google_project.environment.auto_create_network
    error_message = "Projects must be deletion-protected and created without a default network."
  }

  assert {
    condition     = google_storage_bucket.state.name == "test-project-terraform-state" && google_storage_bucket.state.public_access_prevention == "enforced" && google_storage_bucket.state.versioning[0].enabled && !google_storage_bucket.state.force_destroy
    error_message = "The state bucket must be private and versioned."
  }

  assert {
    condition     = google_storage_bucket.state.location == local.region && google_artifact_registry_repository.web.location == local.region && google_cloud_run_v2_service.web.location == local.region
    error_message = "The state bucket, registry, and Cloud Run service must use the configured region."
  }

  assert {
    condition     = google_cloud_run_v2_service.web.deletion_protection && google_cloud_run_v2_service.web.invoker_iam_disabled && google_cloud_run_v2_service.web.template[0].containers[0].ports[0].container_port == 8080
    error_message = "Cloud Run must stay public, deletion-protected and serve on port 8080."
  }

  assert {
    condition     = google_artifact_registry_repository.web.cleanup_policy_dry_run
    error_message = "Registry cleanup must not delete images until explicitly enabled."
  }
}

run "deployer_cannot_escalate" {
  command = plan

  assert {
    condition     = length(setintersection(local.deployer_roles, ["roles/owner", "roles/editor", "roles/resourcemanager.projectIamAdmin", "roles/iam.serviceAccountAdmin", "roles/iam.workloadIdentityPoolAdmin"])) == 0
    error_message = "CI must not be able to change its own IAM or OIDC trust."
  }
}

run "trust_is_scoped_to_environment" {
  command = plan

  variables {
    environment = "production"
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository == 'FSH-LAB/helgefolelse' && assertion.ref == 'refs/heads/main' && assertion.environment == 'production'"
    error_message = "OIDC trust must require the repository, main and the matching environment."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "preview"
  }

  expect_failures = [var.environment]
}
