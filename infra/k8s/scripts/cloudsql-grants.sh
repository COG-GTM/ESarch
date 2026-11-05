#!/usr/bin/env bash
# Confines each Cloud SQL workload user to its own database. Users created through the Cloud SQL API
# (google_sql_user) get the cloudsqlsuperuser role, i.e. access to every database on the instance.
# Cloud SQL has private IP only, so the statements run from a one-shot mysql pod in the cluster; the
# admin password goes in over stdin, never into the pod spec. Idempotent: re-run after replacing a user.
# Usage (staging/prod):
#   MYSQL_HOST="$(terraform -chdir=infra/terraform/envs/staging output -raw cloudsql_private_ip_address)" \
#   MYSQL_ADMIN_PASSWORD="$(gcloud secrets versions access latest --secret=cloudsql-admin-password --project=<project>)" \
#   infra/k8s/scripts/cloudsql-grants.sh
set -euo pipefail

: "${MYSQL_HOST:?private IP (or host) of the MySQL instance}"
: "${MYSQL_ADMIN_PASSWORD:?password of the admin user}"
ns="${NAMESPACE:-axon-trader}"
admin="${MYSQL_ADMIN_USER:-root}"

sql=""
for pair in appdb:trader-app enginedb:trading-engine; do
  db="${pair%%:*}" user="${pair#*:}"
  sql+="REVOKE IF EXISTS cloudsqlsuperuser FROM '${user}'@'%';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${user}'@'%';
SET DEFAULT ROLE NONE TO '${user}'@'%';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'%';
SHOW GRANTS FOR '${user}'@'%';
"
done

{ printf '%s\n' "${MYSQL_ADMIN_PASSWORD}"; printf '%s' "${sql}"; } |
  kubectl -n "${ns}" run "cloudsql-grants-$(date +%s)" --rm -i --quiet --restart=Never \
    --image=mysql:8.0.46 \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":999,"seccompProfile":{"type":"RuntimeDefault"}}}}' \
    --command -- sh -c 'read -r MYSQL_PWD; export MYSQL_PWD; exec mysql --ssl-mode=REQUIRED --connect-timeout=10 -h "$0" -u "$1"' \
    "${MYSQL_HOST}" "${admin}"
