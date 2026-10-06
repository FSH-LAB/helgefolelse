mock_provider "google" {
  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/123456789/locations/global/workloadIdentityPools/github-actions"
    }
  }
}

mock_provider "github" {}

override_resource {
  target = google_service_account.deployer
  values = {
    name  = "projects/test-project/serviceAccounts/helgefolelse-deployer@test-project.iam.gserviceaccount.com"
    email = "helgefolelse-deployer@test-project.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.runtime
  values = {
    name  = "projects/test-project/serviceAccounts/helgefolelse-runtime@test-project.iam.gserviceaccount.com"
    email = "helgefolelse-runtime@test-project.iam.gserviceaccount.com"
  }
}

variables {
  project_id         = "test-project"
  billing_account_id = "ABCDEF-123456-ABCDEF"
  environment        = "dev"
}

run "gcp_defaults" {
  command = plan

  variables {
    manage_github = false
  }

  assert {
    condition     = length(google_project_service.required) == 7 && alltrue([for service in google_project_service.required : !service.disable_on_destroy && service.project == google_project.environment.project_id])
    error_message = "Required APIs must stay enabled if removed from Terraform state."
  }

  assert {
    condition     = google_project.environment.project_id == "test-project" && google_project.environment.billing_account == "ABCDEF-123456-ABCDEF" && google_project.environment.deletion_policy == "PREVENT"
    error_message = "Terraform must own project creation, billing linkage, and deletion protection."
  }

  assert {
    condition     = google_storage_bucket.state.name == "test-project-terraform-state" && google_storage_bucket.state.uniform_bucket_level_access && google_storage_bucket.state.public_access_prevention == "enforced" && google_storage_bucket.state.versioning[0].enabled && !google_storage_bucket.state.force_destroy
    error_message = "The same configuration must provision a private, versioned state bucket."
  }

  assert {
    condition     = google_cloud_run_v2_service.web.deletion_protection && google_cloud_run_v2_service.web.invoker_iam_disabled && google_cloud_run_v2_service.web.template[0].containers[0].ports[0].container_port == 8080
    error_message = "Cloud Run must remain public, deletion-protected, and serve on port 8080."
  }

  assert {
    condition     = google_artifact_registry_repository.web.cleanup_policy_dry_run && length(google_artifact_registry_repository.web.cleanup_policies) == 2
    error_message = "Importing the registry must preserve its cleanup policies without enabling deletion."
  }

  assert {
    condition     = google_cloud_run_v2_service_iam_member.deployer.role == "roles/run.developer" && google_artifact_registry_repository_iam_member.deployer.role == "roles/artifactregistry.writer" && google_service_account_iam_member.runtime_user.role == "roles/iam.serviceAccountUser"
    error_message = "Deployment permissions must remain scoped to the service, repository, and runtime account."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository == 'FSH-LAB/helgefolelse' && assertion.ref == 'refs/heads/main' && assertion.environment == 'dev'"
    error_message = "OIDC trust must require the exact repository, main branch, and environment."
  }

  assert {
    condition     = length(github_repository_environment.web) == 0 && length(github_actions_environment_variable.deployment) == 0 && length(output.github_environment_variables) == 6
    error_message = "Disabling GitHub management must leave deployment variables available as outputs."
  }
}

run "managed_dev_by_default" {
  command = plan

  assert {
    condition     = length(github_repository_environment.web) == 1 && length(github_repository_environment.web[0].reviewers) == 0 && github_repository_environment_deployment_policy.main[0].branch_pattern == "main" && length(github_actions_environment_variable.deployment) == 6
    error_message = "A fresh dev environment must manage GitHub by default without requiring reviewers."
  }
}

run "managed_production" {
  command = plan

  variables {
    environment       = "production"
    manage_github     = true
    reviewer_user_ids = [12345]
  }

  assert {
    condition     = github_repository_environment.web[0].reviewers[0].users == toset([12345]) && github_repository_environment_deployment_policy.main[0].branch_pattern == "main" && length(github_actions_environment_variable.deployment) == 6
    error_message = "Managed production must require reviewers, restrict deployments to main, and configure all six variables."
  }

  assert {
    condition     = endswith(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.environment == 'production'")
    error_message = "Production must not accept the dev environment's identity."
  }
}

run "reject_unprotected_staging" {
  command = plan

  variables {
    environment   = "staging"
    manage_github = true
  }

  expect_failures = [github_repository_environment.web]
}

run "reject_invalid_environment" {
  command = plan

  variables {
    environment = "preview"
  }

  expect_failures = [var.environment]
}

run "reject_conflicting_parents" {
  command = plan

  variables {
    organization_id = "123456789"
    folder_id       = "987654321"
  }

  expect_failures = [google_project.environment]
}

run "reject_invalid_billing_account" {
  command = plan

  variables {
    billing_account_id = ""
  }

  expect_failures = [var.billing_account_id]
}

run "infrastructure_ci_disabled_by_default" {
  command = plan

  assert {
    condition     = length(google_service_account.infrastructure) == 0 && length(google_project_iam_member.infrastructure) == 0
    error_message = "CI provisioning permissions must be explicitly enabled by an operator."
  }
}

run "infrastructure_ci_identity_boundaries" {
  command = plan

  variables {
    enable_infrastructure_ci = true
  }

  assert {
    condition     = length(google_service_account.infrastructure) == 2 && google_service_account.infrastructure["plan"].account_id != google_service_account.infrastructure["apply"].account_id
    error_message = "Planning and applying must use separate identities."
  }

  assert {
    condition     = alltrue([for grant in google_project_iam_member.infrastructure : !contains(["roles/owner", "roles/editor", "roles/resourcemanager.projectCreator", "roles/billing.user"], grant.role)])
    error_message = "Routine CI must not receive broad owner/editor or initial provisioning permissions."
  }

  assert {
    condition     = alltrue([for key, grant in google_project_iam_member.infrastructure : contains(tolist(local.infrastructure_roles.plan), grant.role) if startswith(key, "plan/")]) && length(google_storage_bucket_iam_member.infrastructure_state) == 2
    error_message = "The plan identity gets read access plus bucket-scoped state/lock object access."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.infrastructure[0].attribute_condition == "assertion.repository == 'FSH-LAB/helgefolelse' && assertion.ref == 'refs/heads/main' && assertion.workflow_ref == 'FSH-LAB/helgefolelse/.github/workflows/infrastructure.yml@refs/heads/main' && assertion.environment in ['infra-plan-dev', 'infra-dev']" && alltrue([for grant in google_service_account_iam_member.infrastructure_federation : grant.role == "roles/iam.workloadIdentityUser"])
    error_message = "Only the trusted infrastructure workflow on main may impersonate environment-specific identities."
  }
}