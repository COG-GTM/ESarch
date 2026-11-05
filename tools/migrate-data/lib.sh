# shellcheck shell=bash
# Shared helpers for tools/migrate-data. Source it, do not run it.
#
# Connections are configured per side (SRC = TAS, TGT = Cloud SQL) and per logical database (ENGINEDB, APPDB),
# because on TAS enginedb and appdb are two separate service instances with their own host and credentials:
#   <SIDE>_<DB>_HOST, <SIDE>_<DB>_PORT, <SIDE>_<DB>_USER, <SIDE>_<DB>_PASSWORD, <SIDE>_<DB>_NAME, <SIDE>_<DB>_SSL_MODE
# Each falls back to <SIDE>_HOST, <SIDE>_PORT (3306), <SIDE>_USER, <SIDE>_PASSWORD, <SIDE>_SSL_MODE (PREFERRED).
# <SIDE>_<DB>_NAME defaults to the logical name (enginedb / appdb); TAS p.mysql usually calls it service_instance_db.
# Passwords only travel in MYSQL_PWD (environment), never on a command line.
#
# Client: the local mysql / mysqldump (8.0 client) or, with MYSQL_CLIENT_IMAGE=mysql:8.0.46, the same tools from
# that image on the host network.
# SKIP_TABLES: space-separated tables to leave out of the copy and the checks (e.g. obsolete tables that Hibernate
# `ddl-auto=update` left behind on TAS and that the Flyway baseline does not have). Use only after a human review.

set -euo pipefail

# shellcheck disable=SC2034 # used by the scripts that source this file
MIGRATE_DATA_DBS=(enginedb appdb)
# Flyway's own table exists only on the target and is never copied or compared.
FLYWAY_TABLE=flyway_schema_history
# shellcheck disable=SC2034
EVENT_TABLES=(domain_event_entry snapshot_event_entry)

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# conf SIDE DB FIELD [DEFAULT] -> value of <SIDE>_<DB>_<FIELD>, else <SIDE>_<FIELD>, else DEFAULT
conf() {
  local side=$1 db=$2 field=$3 default=${4-} specific generic
  specific="${side}_${db^^}_${field}"
  generic="${side}_${field}"
  if [ -n "${!specific:-}" ]; then printf '%s' "${!specific}"
  elif [ -n "${!generic:-}" ]; then printf '%s' "${!generic}"
  else printf '%s' "$default"; fi
}

db_name() { conf "$1" "$2" NAME "$2"; }

describe_conn() { # SIDE DB -> user@host:port/name for logs (no password)
  printf '%s@%s:%s/%s' "$(conf "$1" "$2" USER)" "$(conf "$1" "$2" HOST)" "$(conf "$1" "$2" PORT 3306)" "$(db_name "$1" "$2")"
}

require_conn() {
  local side=$1 db=$2 f
  for f in HOST USER PASSWORD; do
    [ -n "$(conf "$side" "$db" "$f")" ] || die "${side}_${db^^}_${f} (or ${side}_${f}) is not set"
  done
}

# run_client TOOL SIDE DB [ARGS...]: runs mysql or mysqldump against SIDE/DB, stdin/stdout passed through.
run_client() {
  local tool=$1 side=$2 db=$3; shift 3
  require_conn "$side" "$db"
  local args=(--host="$(conf "$side" "$db" HOST)" --port="$(conf "$side" "$db" PORT 3306)"
              --user="$(conf "$side" "$db" USER)" --ssl-mode="$(conf "$side" "$db" SSL_MODE PREFERRED)"
              --default-character-set=utf8mb4)
  if [ "$tool" = mysql ]; then args+=(--connect-timeout=10); fi
  if [ -n "${MYSQL_CLIENT_IMAGE:-}" ]; then
    MYSQL_PWD="$(conf "$side" "$db" PASSWORD)" docker run --rm -i --network host -e MYSQL_PWD \
      --entrypoint "$tool" "$MYSQL_CLIENT_IMAGE" "${args[@]}" "$@"
  else
    MYSQL_PWD="$(conf "$side" "$db" PASSWORD)" "$tool" "${args[@]}" "$@"
  fi
}

# q SIDE DB SQL: tab-separated rows, no header, against the side's database for DB.
q() { run_client mysql "$1" "$2" --batch --skip-column-names --database="$(db_name "$1" "$2")" -e "$3"; }

skip_table() { [[ " ${SKIP_TABLES:-} " == *" $1 "* ]]; }

# tables SIDE DB: base tables to copy/compare (no Flyway table, no SKIP_TABLES), byte-sorted so both sides list them in the same order.
tables() {
  local t
  q "$1" "$2" "select table_name from information_schema.tables where table_schema = database()
                 and table_type = 'BASE TABLE' and table_name <> '$FLYWAY_TABLE'" |
    while read -r t; do skip_table "$t" || echo "$t"; done | LC_ALL=C sort
}

has_table() { [ -n "$(q "$1" "$2" "select 1 from information_schema.tables where table_schema = database() and table_name = '$3'")" ]; }
