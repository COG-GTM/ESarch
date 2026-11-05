output "repository_id" {
  description = "Repository id."
  value       = google_artifact_registry_repository.docker.repository_id
}

output "repository_url" {
  description = "Docker image root, e.g. <region>-docker.pkg.dev/<project>/<repo>."
  value       = "${google_artifact_registry_repository.docker.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
}
