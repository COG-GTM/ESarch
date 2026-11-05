output "enabled_services" {
  description = "Enabled project service APIs."
  value       = module.project_services.services
}

output "network_name" {
  description = "VPC name."
  value       = module.network.network_name
}

output "network_self_link" {
  description = "VPC self link."
  value       = module.network.network_self_link
}

output "subnet_name" {
  description = "Private GKE subnet name."
  value       = module.network.subnet_name
}

output "pods_range_name" {
  description = "Secondary range name for pods."
  value       = module.network.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for services."
  value       = module.network.services_range_name
}

output "private_service_access_connection" {
  description = "servicenetworking connection id (Cloud SQL private IP dependency)."
  value       = module.network.private_service_access_connection
}

output "artifact_registry_url" {
  description = "Docker image root for this environment."
  value       = module.artifact_registry.repository_url
}

output "service_account_emails" {
  description = "Google service account emails keyed by short name."
  value       = module.service_accounts.emails
}

output "secret_ids" {
  description = "Secret Manager secret ids."
  value       = module.secrets.secret_ids
}

output "ci_workload_identity_provider" {
  description = "workload_identity_provider input for google-github-actions/auth."
  value       = module.ci_workload_identity.provider_name
}

output "ci_service_account" {
  description = "service_account input for google-github-actions/auth."
  value       = module.service_accounts.emails["ci-deployer"]
}
