output "emails" {
  description = "Service account emails keyed by short name."
  value       = { for k, sa in google_service_account.this : k => sa.email }
}

output "members" {
  description = "IAM members (serviceAccount:<email>) keyed by short name."
  value       = { for k, sa in google_service_account.this : k => sa.member }
}

output "names" {
  description = "Service account resource names keyed by short name."
  value       = { for k, sa in google_service_account.this : k => sa.name }
}

output "project_role_bindings" {
  description = "Project-level grants as <short name>/<role>."
  value       = sort(keys(google_project_iam_member.project_roles))
}

output "gke_workload_identity_members" {
  description = "Kubernetes principals allowed to impersonate each service account, keyed by short name."
  value = {
    for key in keys(var.service_accounts) : key => sort([
      for k, b in google_service_account_iam_member.gke_workload_identity : b.member if split("/", k)[0] == key
    ])
  }
}
