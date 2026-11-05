locals {
  ref_condition = length(var.allowed_refs) == 0 ? "" : format(
    " && assertion.ref in [%s]",
    join(", ", [for r in var.allowed_refs : format("'%s'", r)])
  )
}

resource "google_iam_workload_identity_pool" "ci" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = var.pool_display_name
  description               = "CI identities (GitHub Actions OIDC) for ${var.github_repository}"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.ci.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub Actions"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.environment"      = "assertion.environment"
  }

  # Only tokens minted for this repository (and, if set, these refs) can be exchanged at all.
  attribute_condition = "assertion.repository == '${var.github_repository}'${local.ref_condition}"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "ci_impersonation" {
  service_account_id = var.ci_service_account_name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.ci.name}/attribute.repository/${var.github_repository}"
}
