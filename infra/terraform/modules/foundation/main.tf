locals {
  sa_prefix = "${var.environment}-"

  service_accounts = {
    "gke-nodes" = {
      display_name = "GKE nodes (${var.environment})"
      description  = "Node pool identity: logs, metrics and image pulls only."
      project_roles = [
        "roles/container.defaultNodeServiceAccount",
      ]
    }
    "trader-app" = {
      display_name = "trader-app workload (${var.environment})"
      description  = "Workload Identity for the trader-app pods."
      project_roles = [
        "roles/cloudsql.client",
      ]
      kubernetes_service_accounts = ["${var.kubernetes_namespace}/${var.kubernetes_service_accounts["trader-app"]}"]
    }
    "trading-engine" = {
      display_name = "trading-engine workload (${var.environment})"
      description  = "Workload Identity for the trading-engine pods."
      project_roles = [
        "roles/cloudsql.client",
      ]
      kubernetes_service_accounts = ["${var.kubernetes_namespace}/${var.kubernetes_service_accounts["trading-engine"]}"]
    }
    "ci-deployer" = {
      display_name = "CI deployer (${var.environment})"
      description  = "Impersonated by GitHub Actions through Workload Identity Federation: pushes images, deploys Helm releases."
      project_roles = [
        "roles/container.developer",
      ]
    }
  }
}

module "project_services" {
  source = "../project-services"

  project_id = var.project_id
  services   = var.services
}

module "network" {
  source = "../network"

  project_id                    = var.project_id
  region                        = var.region
  network_name                  = "${var.name_prefix}-${var.environment}"
  subnet_name                   = "${var.name_prefix}-${var.environment}-gke"
  subnet_cidr                   = var.subnet_cidr
  pods_cidr                     = var.pods_cidr
  services_cidr                 = var.services_cidr
  enable_private_service_access = var.enable_private_service_access
  nat_log_filter                = var.nat_log_filter

  depends_on = [module.project_services]
}

module "service_accounts" {
  source = "../service-accounts"

  project_id                            = var.project_id
  name_prefix                           = local.sa_prefix
  service_accounts                      = local.service_accounts
  enable_gke_workload_identity_bindings = var.enable_gke_workload_identity_bindings

  depends_on = [module.project_services]
}

module "artifact_registry" {
  source = "../artifact-registry"

  project_id             = var.project_id
  location               = var.region
  repository_id          = "${var.name_prefix}-${var.environment}"
  immutable_tags         = var.artifact_registry_immutable_tags
  cleanup_policy_dry_run = var.artifact_registry_cleanup_dry_run
  reader_members         = { "gke-nodes" = module.service_accounts.members["gke-nodes"] }
  writer_members         = { "ci-deployer" = module.service_accounts.members["ci-deployer"] }

  depends_on = [module.project_services]
}

module "secrets" {
  source = "../managed-secrets"

  project_id = var.project_id
  secrets = {
    for secret_id, accessors in var.secrets : secret_id => {
      accessors = { for sa in accessors : sa => module.service_accounts.members[sa] }
    }
  }

  depends_on = [module.project_services]
}

module "ci_workload_identity" {
  source = "../workload-identity-federation"

  project_id              = var.project_id
  pool_id                 = var.wif_pool_id
  github_repository       = var.github_repository
  allowed_refs            = var.ci_allowed_refs
  ci_service_account_name = module.service_accounts.names["ci-deployer"]

  depends_on = [module.project_services]
}
