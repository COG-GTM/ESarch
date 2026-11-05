output "network_id" {
  description = "VPC id."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "VPC name."
  value       = google_compute_network.this.name
}

output "network_self_link" {
  description = "VPC self link (Cloud SQL private_network)."
  value       = google_compute_network.this.self_link
}

output "subnet_id" {
  description = "Private subnet id."
  value       = google_compute_subnetwork.private.id
}

output "subnet_name" {
  description = "Private subnet name."
  value       = google_compute_subnetwork.private.name
}

output "pods_range_name" {
  description = "Secondary range name for GKE pods (ip_allocation_policy.cluster_secondary_range_name)."
  value       = var.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for GKE services (ip_allocation_policy.services_secondary_range_name)."
  value       = var.services_range_name
}

output "private_service_access_connection" {
  description = "servicenetworking connection id, or null when disabled."
  value       = var.enable_private_service_access ? google_service_networking_connection.private_service_access[0].id : null
}
