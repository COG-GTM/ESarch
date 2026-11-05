# Offline unit tests: google and random are mocked, so no credentials or project are needed.
mock_provider "google" {
  mock_resource "google_sql_database_instance" {
    defaults = {
      connection_name    = "axon-trader-staging-placeholder:us-central1:esarch-staging-mysql"
      private_ip_address = "10.20.0.3"
    }
  }
}

mock_provider "random" {}

variables {
  project_id        = "axon-trader-staging-placeholder"
  region            = "us-central1"
  environment       = "staging"
  network_self_link = "projects/axon-trader-staging-placeholder/global/networks/esarch-staging"
  user_password_secrets = {
    "trader-app"     = "projects/axon-trader-staging-placeholder/secrets/trader-app-db-password"
    "trading-engine" = "projects/axon-trader-staging-placeholder/secrets/trading-engine-db-password"
  }
  admin_password_secret    = "projects/axon-trader-staging-placeholder/secrets/cloudsql-admin-password"
  rabbitmq_password_secret = "projects/axon-trader-staging-placeholder/secrets/rabbitmq-password"
}

run "staging_defaults" {
  command = apply

  assert {
    condition     = google_sql_database_instance.mysql.name == "esarch-staging-mysql" && google_sql_database_instance.mysql.database_version == "MYSQL_8_0"
    error_message = "Expected one MySQL 8.0 instance named esarch-staging-mysql."
  }

  assert {
    condition = (
      google_sql_database_instance.mysql.settings[0].ip_configuration[0].ipv4_enabled == false &&
      google_sql_database_instance.mysql.settings[0].ip_configuration[0].private_network == var.network_self_link &&
      google_sql_database_instance.mysql.settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY"
    )
    error_message = "The instance must be private IP only, in the foundation VPC, with encrypted connections only."
  }

  assert {
    condition     = output.databases == tomap({ "appdb" = "trader-app", "enginedb" = "trading-engine" })
    error_message = "Expected appdb owned by trader-app and enginedb owned by trading-engine."
  }

  assert {
    condition     = alltrue([for d in google_sql_database.this : d.charset == "utf8mb4" && d.deletion_policy == "ABANDON"])
    error_message = "Databases must be utf8mb4 and never dropped by terraform destroy."
  }

  assert {
    condition = (
      google_sql_database_instance.mysql.settings[0].backup_configuration[0].enabled &&
      !google_sql_database_instance.mysql.settings[0].backup_configuration[0].binary_log_enabled &&
      google_sql_database_instance.mysql.settings[0].availability_type == "ZONAL"
    )
    error_message = "Staging: automated backups on, PITR off, zonal."
  }

  assert {
    condition     = google_sql_database_instance.mysql.deletion_protection && google_sql_database_instance.mysql.settings[0].deletion_protection_enabled
    error_message = "Deletion protection must be on by default."
  }

  assert {
    condition = output.password_secret_versions == tomap({
      "cloudsql-root"     = "projects/axon-trader-staging-placeholder/secrets/cloudsql-admin-password"
      "db-trader-app"     = "projects/axon-trader-staging-placeholder/secrets/trader-app-db-password"
      "db-trading-engine" = "projects/axon-trader-staging-placeholder/secrets/trading-engine-db-password"
      "rabbitmq-app"      = "projects/axon-trader-staging-placeholder/secrets/rabbitmq-password"
    })
    error_message = "Every generated password must land in its documented Secret Manager secret."
  }

  assert {
    condition = (
      google_sql_user.this["appdb"].password == random_password.this["db-trader-app"].result &&
      google_secret_manager_secret_version.this["db-trader-app"].secret_data == random_password.this["db-trader-app"].result &&
      google_sql_database_instance.mysql.root_password == random_password.this["cloudsql-root"].result
    )
    error_message = "Cloud SQL users and Secret Manager must hold the same generated password."
  }

  assert {
    condition     = alltrue([for p in random_password.this : p.length == 32 && p.special == false])
    error_message = "Passwords must be 32 URI-safe characters."
  }
}

run "prod_ha_and_pitr" {
  command = plan

  variables {
    project_id                     = "axon-trader-prod-placeholder"
    environment                    = "prod"
    availability_type              = "REGIONAL"
    point_in_time_recovery_enabled = true
    retained_backups               = 30
    tier                           = "db-custom-2-7680"
  }

  assert {
    condition = (
      google_sql_database_instance.mysql.name == "esarch-prod-mysql" &&
      google_sql_database_instance.mysql.settings[0].availability_type == "REGIONAL" &&
      google_sql_database_instance.mysql.settings[0].backup_configuration[0].binary_log_enabled &&
      google_sql_database_instance.mysql.settings[0].backup_configuration[0].transaction_log_retention_days == 7 &&
      google_sql_database_instance.mysql.settings[0].backup_configuration[0].backup_retention_settings[0].retained_backups == 30
    )
    error_message = "Prod: regional HA, PITR with 7 days of binary logs, 30 backups."
  }
}

run "rejects_short_secret_ids" {
  command = plan

  variables {
    rabbitmq_password_secret = "projects/axon-trader-staging-placeholder/secrets/rabbitmq-password"
    user_password_secrets = {
      "trader-app"     = "trader-app-db-password"
      "trading-engine" = "projects/axon-trader-staging-placeholder/secrets/trading-engine-db-password"
    }
  }

  expect_failures = [var.user_password_secrets]
}

run "rejects_shared_user" {
  command = plan

  variables {
    databases = { "appdb" = "trader-app", "enginedb" = "trader-app" }
  }

  expect_failures = [var.databases]
}
