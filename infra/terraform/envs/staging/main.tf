locals {
  environment = "staging"
}

module "foundation" {
  source = "../../modules/foundation"

  project_id  = var.project_id
  region      = var.region
  environment = local.environment

  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr

  artifact_registry_immutable_tags  = var.artifact_registry_immutable_tags
  artifact_registry_cleanup_dry_run = var.artifact_registry_cleanup_dry_run

  kubernetes_namespace                  = var.kubernetes_namespace
  enable_gke_workload_identity_bindings = var.enable_gke_workload_identity_bindings

  wif_pool_id       = var.wif_pool_id
  github_repository = var.github_repository
  ci_allowed_refs   = var.ci_allowed_refs
}
