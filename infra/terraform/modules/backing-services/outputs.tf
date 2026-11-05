output "instance_name" {
  description = "Cloud SQL instance name."
  value       = google_sql_database_instance.mysql.name
}

output "instance_connection_name" {
  description = "<project>:<region>:<instance>, the Cloud SQL Auth Proxy argument."
  value       = google_sql_database_instance.mysql.connection_name
}

output "private_ip_address" {
  description = "Private IP of the instance in the VPC."
  value       = google_sql_database_instance.mysql.private_ip_address
}

output "databases" {
  description = "Database name -> MySQL user."
  value       = tomap({ for db, user in var.databases : google_sql_database.this[db].name => google_sql_user.this[db].name })
}

output "password_secret_versions" {
  description = "Secret Manager versions written by this module, keyed by credential."
  value       = tomap({ for k, v in google_secret_manager_secret_version.this : k => v.secret })
}
