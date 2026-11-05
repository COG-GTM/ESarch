output "state_bucket" {
  description = "State bucket name; use it as `bucket` in envs/*/backend.hcl."
  value       = google_storage_bucket.tfstate.name
}
