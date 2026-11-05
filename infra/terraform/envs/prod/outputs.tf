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
