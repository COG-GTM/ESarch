#!/usr/bin/env bash
# Copies enginedb and appdb from the TAS source (SRC_*) into the Cloud SQL target (TGT_*) with mysqldump.
#   dump   mysqldump --single-transaction of the rows only (no CREATE TABLE: the schema comes from the Flyway V1
#          baseline on the target), one consistent snapshot per database, into $DUMP_DIR/<db>.sql. Read-only on TAS.
#   load   checks the target (Flyway V1 applied, nobody connected, tables empty unless TARGET_WIPE=yes), then in one
#          session per database empties every copied table and loads the dump.
#   all    dump then load (default).
# Writes the timings (seconds, rows, bytes) to $DUMP_DIR/timings.tsv for sizing the cutover freeze.
# The dump files hold production trading data: keep $DUMP_DIR on an encrypted disk that is not synced anywhere,
# never commit it (target/ is git-ignored) and delete it once the rollback window has closed.
# Connection variables: see lib.sh.
# Usage: tools/migrate-data/copy.sh [all|dump|load] [enginedb|appdb ...]
# shellcheck source=tools/migrate-data/lib.sh
source "$(dirname "$0")/lib.sh"

mode=${1:-all}; [ $# -gt 0 ] && shift
case "$mode" in all|dump|load) ;; *) die "usage: $0 [all|dump|load] [enginedb|appdb ...]" ;; esac
dbs=("$@"); [ ${#dbs[@]} -gt 0 ] || dbs=("${MIGRATE_DATA_DBS[@]}")
DUMP_DIR=${DUMP_DIR:-target/migrate-data/dump}
mkdir -p "$DUMP_DIR"; chmod 700 "$DUMP_DIR"
timings="$DUMP_DIR/timings.tsv"
[ -f "$timings" ] || printf 'step\tdb\tseconds\trows\tbytes\n' >"$timings"

now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }
total_rows() { local side=$1 db=$2 t n=0; for t in $(tables "$side" "$db"); do n=$((n + $(q "$side" "$db" "select count(*) from \`$t\`"))); done; echo "$n"; }

dump() {
  local db=$1 file="$DUMP_DIR/$1.sql" start t ignore=()
  for t in $FLYWAY_TABLE ${SKIP_TABLES:-}; do ignore+=(--ignore-table="$(db_name SRC "$db").$t"); done
  log "dump $db from $(describe_conn SRC "$db") -> $file"
  start=$(now)
  # --single-transaction: one consistent InnoDB snapshot without locking TAS tables.
  # --no-create-info / --skip-triggers: rows only. --complete-insert: column names in every INSERT, so a different
  # column order between the Hibernate-created source and the Flyway target does not matter. --hex-blob: event
  # payloads as hex. --column-statistics=0: an 8.0 mysqldump against a 5.7 server. --set-gtid-purged=OFF: no GTID
  # statements Cloud SQL would refuse. --no-tablespaces: no PROCESS privilege needed on the source.
  run_client mysqldump SRC "$db" --single-transaction --quick --no-create-info --skip-triggers --complete-insert \
    --hex-blob --column-statistics=0 --set-gtid-purged=OFF --no-tablespaces --skip-comments "${ignore[@]}" \
    "$(db_name SRC "$db")" >"$file.partial"
  mv "$file.partial" "$file"
  printf 'dump\t%s\t%s\t%s\t%s\n' "$db" "$(elapsed "$start")" "$(total_rows SRC "$db")" "$(stat -c %s "$file")" | tee -a "$timings"
}

check_target() {
  local db=$1 sessions nonempty=() t
  has_table TGT "$db" "$FLYWAY_TABLE" ||
    die "$db: no $FLYWAY_TABLE on the target; start the GKE deployment once so Flyway applies V1, then scale it to 0"
  [ -n "$(q TGT "$db" "select 1 from $FLYWAY_TABLE where version = '1' and success = 1")" ] ||
    die "$db: Flyway V1 is not applied successfully on the target"
  [ -z "$(q TGT "$db" "select 1 from $FLYWAY_TABLE where success = 0")" ] || die "$db: failed Flyway migration on the target"
  sessions=$(q TGT "$db" "select concat(user, '@', substring_index(host, ':', 1)) from information_schema.processlist
                          where db = database() and id <> connection_id()" | paste -sd ' ')
  [ -z "$sessions" ] || die "$db: sessions still connected to the target ($sessions); scale the GKE deployments to 0 first"
  for t in $(tables TGT "$db"); do
    [ "$t" = hibernate_sequence ] && continue # V1 seeds it with one row
    [ -z "$(q TGT "$db" "select 1 from \`$t\` limit 1")" ] || nonempty+=("$t")
  done
  if [ ${#nonempty[@]} -gt 0 ] && [ "${TARGET_WIPE:-}" != yes ]; then
    die "$db: target tables already hold rows (${nonempty[*]}); set TARGET_WIPE=yes to replace them with the copy"
  fi
}

load() {
  local db=$1 file="$DUMP_DIR/$1.sql" start t
  [ -s "$file" ] || die "$db: no dump at $file"
  check_target "$db"
  log "load $file -> $(describe_conn TGT "$db")"
  start=$(now)
  {
    echo "SET FOREIGN_KEY_CHECKS = 0;"
    for t in $(tables TGT "$db"); do echo "TRUNCATE TABLE \`$t\`;"; done
    cat "$file"
    echo "SET FOREIGN_KEY_CHECKS = 1;"
  } | run_client mysql TGT "$db" --database="$(db_name TGT "$db")" --batch
  printf 'load\t%s\t%s\t%s\t%s\n' "$db" "$(elapsed "$start")" "$(total_rows TGT "$db")" "$(stat -c %s "$file")" | tee -a "$timings"
}

for db in "${dbs[@]}"; do
  case "$mode" in
    dump) dump "$db" ;;
    load) load "$db" ;;
    all) dump "$db"; load "$db" ;;
  esac
done
log "timings in $timings"
