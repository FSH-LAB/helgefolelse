terraform {
  required_version = ">= 1.9, < 2.0"

  # Bucket and prefix are passed at init; see README.md.
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = local.region
}
