# Offline unit tests: the google provider is mocked, so no credentials or project are needed.
mock_provider "google" {
  mock_resource "google_container_cluster" {
    defaults = {
      workload_identity_config = [{ workload_pool = "axon-trader-staging-placeholder.svc.id.goog" }]
    }
  }
}

variables {
  project_id                 = "axon-trader-staging-placeholder"
  region                     = "us-central1"
  name                       = "esarch-staging"
  network_self_link          = "https://www.googleapis.com/compute/v1/projects/axon-trader-staging-placeholder/global/networks/esarch-staging"
  subnet_name                = "esarch-staging-gke"
  pods_range_name            = "pods"
  services_range_name        = "services"
  node_service_account_email = "staging-gke-nodes@axon-trader-staging-placeholder.iam.gserviceaccount.com"
  master_ipv4_cidr_block     = "172.16.0.0/28"
}

run "autopilot_cluster_settings" {
  command = apply

  assert {
    condition     = google_container_cluster.this.enable_autopilot == true
    error_message = "Cluster must be GKE Autopilot."
  }

  assert {
    condition     = google_container_cluster.this.location == "us-central1"
    error_message = "Cluster must be regional (location = region)."
  }

  assert {
    condition     = google_container_cluster.this.private_cluster_config[0].enable_private_nodes == true
    error_message = "Nodes must be private."
  }

  assert {
    condition     = google_container_cluster.this.private_cluster_config[0].enable_private_endpoint == false && google_container_cluster.this.private_cluster_config[0].master_ipv4_cidr_block == "172.16.0.0/28"
    error_message = "Control plane endpoint settings unexpected."
  }

  assert {
    condition     = google_container_cluster.this.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "Dataplane V2 (NetworkPolicy enforcement) must be enabled."
  }

  assert {
    condition     = google_container_cluster.this.release_channel[0].channel == "REGULAR"
    error_message = "Release channel must be REGULAR."
  }

  assert {
    condition     = google_container_cluster.this.workload_identity_config[0].workload_pool == "axon-trader-staging-placeholder.svc.id.goog"
    error_message = "Workload Identity must use the project pool."
  }

  assert {
    condition     = google_container_cluster.this.monitoring_config[0].managed_prometheus[0].enabled == true
    error_message = "Managed Service for Prometheus (managed collection) must be enabled."
  }

  assert {
    condition     = google_container_cluster.this.gateway_api_config[0].channel == "CHANNEL_STANDARD"
    error_message = "Gateway API must be enabled."
  }

  assert {
    condition     = google_container_cluster.this.networking_mode == "VPC_NATIVE" && google_container_cluster.this.ip_allocation_policy[0].cluster_secondary_range_name == "pods" && google_container_cluster.this.ip_allocation_policy[0].services_secondary_range_name == "services"
    error_message = "Cluster must be VPC-native on the foundation secondary ranges."
  }

  assert {
    condition     = google_container_cluster.this.cluster_autoscaling[0].auto_provisioning_defaults[0].service_account == "staging-gke-nodes@axon-trader-staging-placeholder.iam.gserviceaccount.com"
    error_message = "Autopilot nodes must run as the least-privilege gke-nodes service account."
  }

  assert {
    condition     = google_container_cluster.this.master_authorized_networks_config[0].gcp_public_cidrs_access_enabled == false && length(google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks) == 0
    error_message = "Control plane must not be open to Google public CIDRs or any CIDR by default."
  }

  assert {
    condition     = google_container_cluster.this.deletion_protection == true
    error_message = "Deletion protection must default on."
  }
}

run "authorized_networks" {
  command = plan

  variables {
    master_authorized_networks = [{ cidr_block = "203.0.113.0/24", display_name = "ops-vpn" }]
  }

  assert {
    condition     = [for b in google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks : b.cidr_block] == ["203.0.113.0/24"]
    error_message = "Authorized networks not applied."
  }
}

run "rejects_non_28_master_range" {
  command = plan

  variables {
    master_ipv4_cidr_block = "172.16.0.0/24"
  }

  expect_failures = [var.master_ipv4_cidr_block]
}

run "rejects_unknown_release_channel" {
  command = plan

  variables {
    release_channel = "EXTENDED"
  }

  expect_failures = [var.release_channel]
}
