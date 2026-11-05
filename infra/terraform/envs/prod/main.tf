locals {
  environment = "prod"
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

  wif_pool_id                = var.wif_pool_id
  github_repository          = var.github_repository
  github_repository_id       = var.github_repository_id
  github_repository_owner_id = var.github_repository_owner_id
  ci_allowed_refs            = var.ci_allowed_refs
}

module "gke" {
  source = "../../modules/gke"

  project_id = var.project_id
  region     = var.region
  name       = "esarch-${local.environment}"

  network_self_link   = module.foundation.network_self_link
  subnet_name         = module.foundation.subnet_name
  pods_range_name     = module.foundation.pods_range_name
  services_range_name = module.foundation.services_range_name

  node_service_account_email = module.foundation.service_account_emails["gke-nodes"]

  release_channel            = "REGULAR"
  master_ipv4_cidr_block     = var.gke_master_ipv4_cidr_block
  enable_private_endpoint    = var.gke_enable_private_endpoint
  master_authorized_networks = var.gke_master_authorized_networks
  deletion_protection        = var.gke_deletion_protection

  labels = merge(var.labels, {
    app         = "axon-trader"
    environment = local.environment
  })
}

module "gke_platform" {
  source = "../../modules/gke-platform"

  project_id          = var.project_id
  environment         = local.environment
  hostnames           = var.gateway_hostnames
  smoke_test_accessor = "serviceAccount:${module.foundation.service_account_emails["trader-app"]}"

  depends_on = [module.foundation]
}
