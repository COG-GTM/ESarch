terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 7.0"
    }
  }

  # Partial configuration: the bucket comes from `terraform init -backend-config=backend.hcl`
  # (see backend.hcl.example) so no project-specific name is committed.
  backend "gcs" {
    prefix = "esarch/prod"
  }
}
