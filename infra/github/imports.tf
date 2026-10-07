# One-time adoption of the existing GitHub settings. Delete this file after the first apply.
locals {
  existing_policies = {
    dev        = "61632855"
    staging    = "61738103"
    production = "61738176"
  }
}

import {
  for_each = local.environments
  to       = github_repository_environment.env[each.key]
  id       = "${local.repository}:${each.key}"
}

import {
  for_each = local.existing_policies
  to       = github_repository_environment_deployment_policy.main[each.key]
  id       = "${local.repository}:${each.key}:${each.value}"
}

import {
  for_each = local.variables
  to       = github_actions_environment_variable.env[each.key]
  id       = "${local.repository}:${each.value.environment}:${each.value.name}"
}
