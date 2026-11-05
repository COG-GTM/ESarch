# Only the secret containers and their IAM live here. Secret values are added out of band
# (gcloud secrets versions add) so they never reach Terraform state.
# Accessors are keyed by a static name so for_each keys are known at plan time even when the
# member (e.g. a service account created in the same run) is not.
locals {
  accessor_bindings = {
    for pair in flatten([
      for secret_id, cfg in var.secrets : [
        for name, member in cfg.accessors : {
          key       = "${secret_id}/${name}"
          secret_id = secret_id
          member    = member
        }
      ]
    ]) : pair.key => pair
  }
}

resource "google_secret_manager_secret" "this" {
  for_each = var.secrets

  project   = var.project_id
  secret_id = each.key
  labels    = merge(var.labels, each.value.labels)

  replication {
    dynamic "auto" {
      for_each = length(var.replica_locations) == 0 ? [1] : []
      content {}
    }

    dynamic "user_managed" {
      for_each = length(var.replica_locations) > 0 ? [1] : []
      content {
        dynamic "replicas" {
          for_each = var.replica_locations
          content {
            location = replicas.value
          }
        }
      }
    }
  }
}

resource "google_secret_manager_secret_iam_member" "accessors" {
  for_each = local.accessor_bindings

  project   = var.project_id
  secret_id = google_secret_manager_secret.this[each.value.secret_id].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member
}
