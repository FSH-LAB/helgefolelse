terraform {
  required_version = ">= 1.9, < 2.0"

  backend "gcs" {
    bucket = "generated-mote-510411-v8-terraform-state"
    prefix = "helgefolelse/github"
  }

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "github" {
  owner = "FSH-LAB"
}

locals {
  repository = "helgefolelse"
  reviewers  = [38140980] # FredrikSundt-Hansen

  environments = {
    dev        = { project_id = "quick-pointer-510215-s6", project_number = "475851250732" }
    staging    = { project_id = "hazel-core-510411-b1", project_number = "288502766582" }
    production = { project_id = "generated-mote-510411-v8", project_number = "423756211110" }
  }

  variables = merge([
    for name, env in local.environments : {
      for key, value in {
        GCP_PROJECT_ID             = env.project_id
        GCP_WIF_PROVIDER           = "projects/${env.project_number}/locations/global/workloadIdentityPools/github-actions/providers/github"
        GCP_DEPLOY_SERVICE_ACCOUNT = "helgefolelse-deployer@${env.project_id}.iam.gserviceaccount.com"
      } : "${name}/${key}" => { environment = name, name = key, value = value }
    }
  ]...)
}

resource "github_repository_environment" "env" {
  for_each = local.environments

  repository  = local.repository
  environment = each.key

  dynamic "reviewers" {
    for_each = each.key == "dev" ? [] : [1]
    content {
      users = local.reviewers
    }
  }

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "main" {
  for_each = local.environments

  repository     = local.repository
  environment    = github_repository_environment.env[each.key].environment
  branch_pattern = "main"
}

resource "github_actions_environment_variable" "env" {
  for_each = local.variables

  repository    = local.repository
  environment   = github_repository_environment.env[each.value.environment].environment
  variable_name = each.value.name
  value         = each.value.value
}
