# Offline unit tests: the google provider is mocked, so no credentials or project are needed.
mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      member = "serviceAccount:mock-sa@example-project.iam.gserviceaccount.com"
      name   = "projects/example-project/serviceAccounts/mock-sa@example-project.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/123/locations/global/workloadIdentityPools/esarch-ci-test"
    }
  }
}

variables {
  project_id                 = "example-project"
  region                     = "us-central1"
  environment                = "staging"
  subnet_cidr                = "10.10.0.0/20"
  pods_cidr                  = "10.12.0.0/16"
  services_cidr              = "10.13.0.0/20"
  wif_pool_id                = "esarch-ci-test"
  github_repository          = "COG-GTM/ESarch"
  github_repository_id       = "1340826081"
  github_repository_owner_id = "211054393"
}

run "foundation_defaults" {
  command = apply

  assert {
    condition     = length(module.project_services.services) == 13
    error_message = "Expected the 13 foundation APIs to be enabled."
  }

  assert {
    condition     = module.network.subnet_name == "esarch-staging-gke" && module.network.private_service_access_connection != null
    error_message = "Subnet name or private services access unexpected."
  }

  assert {
    condition     = keys(module.service_accounts.emails) == ["ci-deployer", "gke-nodes", "trader-app", "trading-engine"]
    error_message = "Unexpected service account set."
  }

  assert {
    condition = module.service_accounts.project_role_bindings == tolist([
      "ci-deployer/roles/container.developer",
      "gke-nodes/roles/container.defaultNodeServiceAccount",
      "trader-app/roles/cloudsql.client",
      "trading-engine/roles/cloudsql.client",
    ])
    error_message = "Each service account should get exactly one project-level role."
  }

  assert {
    condition     = alltrue([for m in values(module.service_accounts.gke_workload_identity_members) : length(m) == 0])
    error_message = "KSA bindings must stay off until the cluster exists."
  }

  assert {
    condition = module.secrets.accessor_bindings == tolist([
      "rabbitmq-password/trader-app",
      "rabbitmq-password/trading-engine",
      "trader-app-db-password/trader-app",
      "trading-engine-db-password/trading-engine",
    ])
    error_message = "Secret accessors should be per secret and per workload only."
  }

  assert {
    condition     = module.ci_workload_identity.attribute_condition == "assertion.repository == 'COG-GTM/ESarch' && assertion.repository_id == '1340826081' && assertion.repository_owner_id == '211054393'"
    error_message = "WIF provider must be pinned to the repository name and immutable repository/owner ids."
  }

  assert {
    condition     = module.ci_workload_identity.ci_principal_set == "principalSet://iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/esarch-ci-test/attribute.repository_id/1340826081"
    error_message = "CI impersonation must be scoped to the repository principalSet."
  }
}

run "prod_ref_restriction_and_ksa_bindings" {
  command = apply

  variables {
    environment                           = "prod"
    ci_allowed_refs                       = ["refs/heads/master"]
    ci_allowed_environments               = ["production"]
    enable_gke_workload_identity_bindings = true
  }

  assert {
    condition     = module.ci_workload_identity.attribute_condition == "assertion.repository == 'COG-GTM/ESarch' && assertion.repository_id == '1340826081' && assertion.repository_owner_id == '211054393' && assertion.ref in ['refs/heads/master'] && assertion.environment in ['production']"
    error_message = "Ref or production environment restriction missing from the WIF attribute condition."
  }

  assert {
    condition = tolist(flatten(values(module.service_accounts.gke_workload_identity_members))) == tolist([
      "serviceAccount:example-project.svc.id.goog[axon-trader/trader-app]",
      "serviceAccount:example-project.svc.id.goog[axon-trader/trading-engine]",
    ])
    error_message = "KSA -> GSA bindings should cover exactly the two workloads."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "dev"
  }

  expect_failures = [var.environment]
}
