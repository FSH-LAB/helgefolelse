variable "environment" {
  type = string

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be dev, staging, or production."
  }
}

variable "project_id" {
  type = string
}

variable "project_name" {
  type = string
}

variable "folder_id" {
  type    = string
  default = null
}

variable "billing_account_id" {
  description = "Only needed when creating a project; later changes are ignored."
  type        = string
  default     = null
}

variable "region" {
  type    = string
  default = "europe-north2"
}

variable "github_repository" {
  type    = string
  default = "FSH-LAB/helgefolelse"
}
