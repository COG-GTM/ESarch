output "network_name" {
  description = "VPC name."
  value       = module.foundation.network_name
}

output "subnet_name" {
  description = "Private GKE subnet name."
  value       = module.foundation.subnet_name
}

output "pods_range_name" {
  description = "Secondary range name for pods."
  value       = module.foundation.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for services."
  value       = module.foundation.services_range_name
}

output "network_self_link" {
  description = "VPC self link (Cloud SQL private network)."
  value       = module.foundation.network_self_link
}

output "artifact_registry_url" {
  description = "Docker image root."
  value       = module.foundation.artifact_registry_url
}

output "service_account_emails" {
  description = "Google service account emails."
  value       = module.foundation.service_account_emails
}

output "secret_ids" {
  description = "Secret Manager secret ids."
  value       = module.foundation.secret_ids
}

output "ci_workload_identity_provider" {
  description = "workload_identity_provider for google-github-actions/auth."
  value       = module.foundation.ci_workload_identity_provider
}

output "ci_service_account" {
  description = "service_account for google-github-actions/auth."
  value       = module.foundation.ci_service_account
}

output "gke_cluster_name" {
  description = "GKE cluster name."
  value       = module.gke.name
}

output "gke_cluster_location" {
  description = "GKE cluster location."
  value       = module.gke.location
}

output "gke_get_credentials" {
  description = "Command that writes a kubeconfig entry for the cluster."
  value       = "gcloud container clusters get-credentials ${module.gke.name} --region ${module.gke.location} --project ${var.project_id}"
}

output "gateway_address" {
  description = "Gateway IP; create a DNS A record for each gateway hostname pointing here."
  value       = module.gke_platform.gateway_address
}

output "cloudsql_instance_connection_name" {
  description = "Cloud SQL instance connection name (Cloud SQL Auth Proxy argument)."
  value       = module.backing_services.instance_connection_name
}

output "cloudsql_private_ip_address" {
  description = "Private IP of the Cloud SQL instance."
  value       = module.backing_services.private_ip_address
}

output "kustomize_env" {
  description = "Values for infra/k8s/overlays/<env>/cluster.env (written by infra/k8s/scripts/cluster-env.sh)."
  value = {
    PROJECT_ID           = var.project_id
    CLUSTER_NAME         = module.gke.name
    CLUSTER_LOCATION     = module.gke.location
    TRADER_APP_GSA       = module.foundation.service_account_emails["trader-app"]
    TRADING_ENGINE_GSA   = module.foundation.service_account_emails["trading-engine"]
    GATEWAY_ADDRESS_NAME = module.gke_platform.gateway_address_name
    CERT_MAP_NAME        = module.gke_platform.certificate_map_name
    SMOKE_HOSTNAME       = var.gateway_hostnames[0]
    SMOKE_SECRET_ID      = module.gke_platform.smoke_test_secret_id

    CLOUDSQL_INSTANCE_CONNECTION_NAME = module.backing_services.instance_connection_name
  }
}

output "dashboard_ids" {
  description = "Cloud Monitoring dashboard ids, by service."
  value       = module.observability.dashboard_ids
}

output "alert_policy_names" {
  description = "Alert policy resource names (pod_restarts, http_5xx, queue_backlog)."
  value       = module.observability.alert_policy_names
}
