output "name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "location" {
  description = "Cluster location (region)."
  value       = google_container_cluster.this.location
}

output "id" {
  description = "Cluster id."
  value       = google_container_cluster.this.id
}

output "endpoint" {
  description = "Control plane endpoint."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "ca_certificate" {
  description = "Base64 cluster CA certificate."
  value       = one(google_container_cluster.this.master_auth[*].cluster_ca_certificate)
  sensitive   = true
}

output "workload_pool" {
  description = "Workload Identity pool (<project>.svc.id.goog)."
  value       = google_container_cluster.this.workload_identity_config[0].workload_pool
}
