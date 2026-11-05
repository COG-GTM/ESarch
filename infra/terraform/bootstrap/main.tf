# One-time root that creates the GCS bucket holding remote state for envs/*. It keeps its own
# state locally; run it once per state project and keep terraform.tfstate out of git.
provider "google" {
  project = var.project_id
}

resource "google_project_service" "storage" {
  project            = var.project_id
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "tfstate" {
  project                     = var.project_id
  name                        = var.bucket_name
  location                    = var.location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = var.labels

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = var.noncurrent_versions_to_keep
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.storage]
}
