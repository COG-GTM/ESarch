provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = merge(var.labels, {
    app         = "axon-trader"
    environment = local.environment
    managed-by  = "terraform"
  })
}
