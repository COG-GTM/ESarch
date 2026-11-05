output "services" {
  description = "Enabled service APIs."
  value       = sort([for s in google_project_service.this : s.service])
}
