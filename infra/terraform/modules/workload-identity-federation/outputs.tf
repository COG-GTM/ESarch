output "pool_name" {
  description = "Full pool resource name."
  value       = google_iam_workload_identity_pool.ci.name
}

output "provider_name" {
  description = "Full provider resource name; the workload_identity_provider input of google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "attribute_condition" {
  description = "CEL condition every exchanged GitHub token must satisfy."
  value       = google_iam_workload_identity_pool_provider.github.attribute_condition
}

output "ci_principal_set" {
  description = "Principal set granted workloadIdentityUser on the CI service account."
  value       = google_service_account_iam_member.ci_impersonation.member
}
