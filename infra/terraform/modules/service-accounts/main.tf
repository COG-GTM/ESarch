locals {
  project_role_bindings = {
    for pair in flatten([
      for key, sa in var.service_accounts : [
        for role in sa.project_roles : {
          key  = "${key}/${role}"
          sa   = key
          role = role
        }
      ]
    ]) : pair.key => pair
  }

  gke_workload_identity_bindings = var.enable_gke_workload_identity_bindings ? {
    for pair in flatten([
      for key, sa in var.service_accounts : [
        for ksa in sa.kubernetes_service_accounts : {
          key    = "${key}/${ksa}"
          sa     = key
          member = "serviceAccount:${var.project_id}.svc.id.goog[${ksa}]"
        }
      ]
    ]) : pair.key => pair
  } : {}
}

resource "google_service_account" "this" {
  for_each = var.service_accounts

  project      = var.project_id
  account_id   = "${var.name_prefix}${each.key}"
  display_name = each.value.display_name
  description  = each.value.description
}

resource "google_project_iam_member" "project_roles" {
  for_each = local.project_role_bindings

  project = var.project_id
  role    = each.value.role
  member  = google_service_account.this[each.value.sa].member
}

# GKE Workload Identity: lets <namespace>/<ksa> act as the Google service account. The
# <project>.svc.id.goog pool only exists once a Workload Identity enabled cluster exists,
# so this stays off until the GKE step has created the cluster.
resource "google_service_account_iam_member" "gke_workload_identity" {
  for_each = local.gke_workload_identity_bindings

  service_account_id = google_service_account.this[each.value.sa].name
  role               = "roles/iam.workloadIdentityUser"
  member             = each.value.member
}
