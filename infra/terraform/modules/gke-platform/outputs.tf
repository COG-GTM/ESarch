output "gateway_address_name" {
  description = "Global address name for the Gateway (spec.addresses NamedAddress)."
  value       = google_compute_global_address.gateway.name
}

output "gateway_address" {
  description = "Gateway IP; point every hostname's DNS A record here."
  value       = google_compute_global_address.gateway.address
}

output "certificate_map_name" {
  description = "Certificate map for the networking.gke.io/certmap Gateway annotation."
  value       = google_certificate_manager_certificate_map.gateway.name
}

output "ssl_policy_name" {
  description = "SSL policy for the Gateway's GCPGatewayPolicy (spec.default.sslPolicy)."
  value       = google_compute_ssl_policy.gateway.name
}

output "certificate_map_entries" {
  description = "Certificate map entry hostnames."
  value       = sort(keys(google_certificate_manager_certificate_map_entry.gateway))
}

output "smoke_test_secret_id" {
  description = "Smoke-test secret id."
  value       = google_secret_manager_secret.smoke_test.secret_id
}
