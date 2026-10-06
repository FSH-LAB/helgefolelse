variable "project_id" {
  description = "Globally unique GCP project ID to create or adopt for this environment."
  type        = string
}

variable "project_name" {
  description = "Project display name. Match the current name when importing to avoid renaming."
  type        = string
  default     = null
}

variable "billing_account_id" {
  description = "Existing billing account to link to the managed project."
  type        = string

  validation {
    condition     = can(regex("^[A-Fa-f0-9]{6}-[A-Fa-f0-9]{6}-[A-Fa-f0-9]{6}$", var.billing_account_id))
    error_message = "Supply a billing account ID in XXXXXX-XXXXXX-XXXXXX format."
  }
}

variable "organization_id" {
  description = "Parent organization ID, or null when using a folder or a personal account."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "Existing parent folder ID, mutually exclusive with organization_id."
  type        = string
  default     = null
}

variable "state_bucket_name" {
  description = "Globally unique state bucket name; defaults to PROJECT_ID-terraform-state."
  type        = string
  default     = null
}

variable "environment" {
  description = "Deployment environment; use a separate backend for each."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be dev, staging, or production."
  }
}

variable "region" {
  description = "Must match the location of existing resources when importing."
  type        = string
  default     = "europe-north2"
}

variable "gar_repository" {
  type    = string
  default = "helgefolelse"
}

variable "cloud_run_service" {
  type    = string
  default = "helgefolelse-web"
}

variable "github_owner" {
  type    = string
  default = "FSH-LAB"
}

variable "github_repository" {
  type    = string
  default = "helgefolelse"
}

variable "manage_github" {
  description = "Manage the GitHub environment, main policy, and variables. Import existing settings first."
  type        = bool
  default     = true
}

variable "reviewer_user_ids" {
  description = "GitHub numeric user IDs with repository access. Required for managed staging/production."
  type        = list(number)
  default     = []

  validation {
    condition     = length(var.reviewer_user_ids) <= 6 && alltrue([for user_id in var.reviewer_user_ids : user_id > 0 && floor(user_id) == user_id])
    error_message = "Supply at most six positive integer GitHub user IDs."
  }
}