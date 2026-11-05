# Offline unit tests: the google provider is mocked, so no credentials or project are needed.
mock_provider "google" {
  mock_resource "google_certificate_manager_certificate" {
    defaults = {
      id = "projects/axon-trader-staging-placeholder/locations/global/certificates/esarch-staging-gateway"
    }
  }
}

variables {
  project_id          = "axon-trader-staging-placeholder"
  environment         = "staging"
  hostnames           = ["hello.staging.example.com", "trader.staging.example.com"]
  smoke_test_accessor = "serviceAccount:staging-trader-app@axon-trader-staging-placeholder.iam.gserviceaccount.com"
}

run "gateway_certificate_and_smoke_secret" {
  command = apply

  assert {
    condition     = output.gateway_address_name == "esarch-staging-gateway" && output.certificate_map_name == "esarch-staging-gateway"
    error_message = "Gateway address or certificate map name unexpected."
  }

  assert {
    condition     = google_certificate_manager_certificate.gateway.managed[0].domains == tolist(["hello.staging.example.com", "trader.staging.example.com"])
    error_message = "The Google-managed certificate must cover every hostname."
  }

  assert {
    condition     = output.certificate_map_entries == tolist(["hello.staging.example.com", "trader.staging.example.com"])
    error_message = "Each hostname needs a certificate map entry."
  }

  assert {
    condition     = alltrue([for e in google_certificate_manager_certificate_map_entry.gateway : e.certificates == tolist([google_certificate_manager_certificate.gateway.id])])
    error_message = "Map entries must point at the managed certificate."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.smoke_test.role == "roles/secretmanager.secretAccessor" && google_secret_manager_secret_iam_member.smoke_test.member == "serviceAccount:staging-trader-app@axon-trader-staging-placeholder.iam.gserviceaccount.com"
    error_message = "Only the trader-app workload may read the smoke-test secret."
  }

  assert {
    condition     = output.smoke_test_secret_id == "platform-smoke-test"
    error_message = "Smoke-test secret id unexpected."
  }
}

run "certificate_map_entry_names_unique_and_bounded" {
  command = plan

  variables {
    hostnames = [
      "a-b.example.com",
      "a.b-example.com",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example.com",
    ]
  }

  assert {
    condition     = length(distinct([for e in google_certificate_manager_certificate_map_entry.gateway : e.name])) == 3
    error_message = "Hostnames that differ only in dots vs hyphens must get distinct entry names."
  }

  assert {
    condition     = alltrue([for e in google_certificate_manager_certificate_map_entry.gateway : can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", e.name))])
    error_message = "Entry names must be valid GCP resource names (<= 63 chars)."
  }
}

run "entry_names_bounded_with_longest_prefix" {
  command = plan

  variables {
    name_prefix = "customer-production-abc"
    environment = "staging-longenv"
    hostnames   = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example.com"]
  }

  assert {
    condition     = alltrue([for e in google_certificate_manager_certificate_map_entry.gateway : can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", e.name))])
    error_message = "Entry names must stay <= 63 chars for the longest allowed prefix and environment."
  }
}

run "rejects_empty_hostnames" {
  command = plan

  variables {
    hostnames = []
  }

  expect_failures = [var.hostnames]
}

run "rejects_duplicate_hostnames" {
  command = plan

  variables {
    hostnames = ["hello.staging.example.com", "hello.staging.example.com"]
  }

  expect_failures = [var.hostnames]
}
