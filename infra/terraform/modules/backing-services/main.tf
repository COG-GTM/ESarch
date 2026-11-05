# Backing services that replace the TAS marketplace instances enginedb / appdb (ClearDB, p.mysql)
# and rabbit (CloudAMQP, p.rabbitmq):
#   - one Cloud SQL for MySQL 8.0 instance, private IP only, one database and one user per workload
#   - generated passwords for those users, the Cloud SQL root user and the RabbitMQ application
#     user, written as versions of the Secret Manager secrets declared by the foundation module.
# The RabbitMQ broker itself runs in-cluster (RabbitMQ Cluster Operator, infra/k8s/backing-services).
#
# Passwords are generated here so Cloud SQL users and Secret Manager never disagree. They are
# therefore in Terraform state: keep the state bucket (bootstrap/) restricted to the platform team.

locals {
  instance_name = "${var.name_prefix}-${var.environment}-mysql"

  # Secret Manager secret (projects/<p>/secrets/<id>) for every generated password.
  password_secrets = merge(
    { for db, user in var.databases : "db-${user}" => var.user_password_secrets[user] },
    {
      "cloudsql-root" = var.admin_password_secret
      "rabbitmq-app"  = var.rabbitmq_password_secret
    },
  )
}

resource "google_sql_database_instance" "mysql" {
  project             = var.project_id
  name                = local.instance_name
  region              = var.region
  database_version    = "MYSQL_8_0"
  root_password       = random_password.this["cloudsql-root"].result
  deletion_protection = var.deletion_protection

  settings {
    tier                        = var.tier
    edition                     = "ENTERPRISE"
    availability_type           = var.availability_type
    disk_type                   = "PD_SSD"
    disk_size                   = var.disk_size_gb
    disk_autoresize             = true
    deletion_protection_enabled = var.deletion_protection
    user_labels                 = var.labels

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_self_link
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      binary_log_enabled             = var.point_in_time_recovery_enabled
      start_time                     = var.backup_start_time
      transaction_log_retention_days = var.point_in_time_recovery_enabled ? var.transaction_log_retention_days : null

      backup_retention_settings {
        retained_backups = var.retained_backups
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = var.maintenance_window.day
      hour         = var.maintenance_window.hour
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = false
      record_client_address   = false
    }

    # CIS Cloud SQL MySQL benchmark flags.
    database_flags {
      name  = "local_infile"
      value = "off"
    }

    database_flags {
      name  = "skip_show_database"
      value = "on"
    }
  }
}

resource "google_sql_database" "this" {
  for_each = var.databases

  project   = var.project_id
  instance  = google_sql_database_instance.mysql.name
  name      = each.key
  charset   = "utf8mb4"
  collation = "utf8mb4_0900_ai_ci"

  # Never DROP DATABASE on destroy: the Axon event stores live here.
  deletion_policy = "ABANDON"
}

# One BUILT_IN user per workload. API-created users get cloudsqlsuperuser (every database); the
# Cloud SQL API cannot grant per database, so infra/k8s/scripts/cloudsql-grants.sh narrows them (README).
resource "google_sql_user" "this" {
  for_each = var.databases

  project  = var.project_id
  instance = google_sql_database_instance.mysql.name
  name     = each.value
  host     = "%"
  type     = "BUILT_IN"
  password = random_password.this["db-${each.value}"].result

  depends_on = [google_sql_database.this]
}

resource "random_password" "this" {
  for_each = local.password_secrets

  length = 32
  # Alphanumeric only, so the values are safe in JDBC/AMQP URIs and shell without escaping.
  special = false
}

resource "google_secret_manager_secret_version" "this" {
  for_each = local.password_secrets

  secret      = each.value
  secret_data = random_password.this[each.key].result
}
