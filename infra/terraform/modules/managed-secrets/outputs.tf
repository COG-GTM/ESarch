output "secret_ids" {
  description = "Secret ids keyed by secret id."
  value       = { for k, s in google_secret_manager_secret.this : k => s.secret_id }
}

output "secret_names" {
  description = "Full secret resource names (projects/<number>/secrets/<id>) keyed by secret id."
  value       = { for k, s in google_secret_manager_secret.this : k => s.name }
}

output "accessor_bindings" {
  description = "secretAccessor grants as <secret id>/<accessor name>."
  value       = sort(keys(google_secret_manager_secret_iam_member.accessors))
}
