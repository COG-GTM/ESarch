# GCP side of the cluster add-ons: the Gateway's global IP and Google-managed certificate
# (Certificate Manager, load balancer authorization) and the Secret Manager smoke-test secret
# the platform ExternalSecret reads.
locals {
  name = "${var.name_prefix}-${var.environment}"

  # Entry names must be unique and <= 63 chars: "<name>-<hostname slice>-<8-char hash of hostname>".
  # The slice gets what is left of the budget (>= 14 chars given the name_prefix/environment limits).
  certificate_map_entry_host_len = 63 - length(local.name) - 10
  certificate_map_entry_names = {
    for host in toset(var.hostnames) : host => format("%s-%s-%s",
      local.name,
      replace(substr(replace(host, ".", "-"), 0, local.certificate_map_entry_host_len), "/-+$/", ""),
      substr(sha256(host), 0, 8),
    )
  }
}

resource "google_compute_global_address" "gateway" {
  project = var.project_id
  name    = "${local.name}-gateway"
}

# Load balancer authorization: Google issues the certificate once each hostname resolves to the
# Gateway address and the certificate map is attached to its HTTPS proxy.
resource "google_certificate_manager_certificate" "gateway" {
  project     = var.project_id
  name        = "${local.name}-gateway"
  description = "Google-managed certificate for the ${var.environment} Gateway."
  scope       = "DEFAULT"
  labels      = var.labels

  managed {
    domains = var.hostnames
  }
}

resource "google_certificate_manager_certificate_map" "gateway" {
  project     = var.project_id
  name        = "${local.name}-gateway"
  description = "Referenced by the networking.gke.io/certmap annotation of the ${var.environment} Gateway."
  labels      = var.labels
}

# TLS 1.2+ with the MODERN profile on the Gateway's HTTPS proxy (GCPGatewayPolicy in infra/k8s/platform/gateway.yaml).
# Without it the load balancer uses the COMPATIBLE profile and still accepts TLS 1.0/1.1.
resource "google_compute_ssl_policy" "gateway" {
  project         = var.project_id
  name            = "${local.name}-gateway"
  description     = "TLS policy of the ${var.environment} Gateway."
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_certificate_manager_certificate_map_entry" "gateway" {
  for_each = toset(var.hostnames)

  project      = var.project_id
  name         = local.certificate_map_entry_names[each.key]
  map          = google_certificate_manager_certificate_map.gateway.name
  hostname     = each.key
  certificates = [google_certificate_manager_certificate.gateway.id]
  labels       = var.labels
}

# Non-sensitive constant: proves an ExternalSecret resolves from Secret Manager end to end.
resource "google_secret_manager_secret" "smoke_test" {
  project   = var.project_id
  secret_id = var.smoke_test_secret_id
  labels    = merge(var.labels, { purpose = "platform-smoke-test" })

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "smoke_test" {
  secret      = google_secret_manager_secret.smoke_test.id
  secret_data = var.smoke_test_value
}

resource "google_secret_manager_secret_iam_member" "smoke_test" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.smoke_test.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = var.smoke_test_accessor
}
