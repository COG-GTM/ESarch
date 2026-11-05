#!/usr/bin/env bash
# Read-only inventory of the TAS source and the Cloud SQL target before a copy ("confirm what data is there first").
# For each database: server settings that matter for the copy (version, character set, sql_mode, binary log / GTID
# for DMS), every table with its exact row count and size, a column-by-column schema comparison of the source
# (created by Hibernate ddl-auto=update on TAS) against the target (Flyway V1 baseline), the target's Flyway history,
# and sessions still connected to the target.
# Exits 1 if the schemas differ (a column or table the target does not have, or a different type / nullability),
# because the copied rows would then not load or `ddl-auto=validate` would reject them.
# Usage: tools/migrate-data/preflight.sh [enginedb|appdb ...]
# shellcheck source=tools/migrate-data/lib.sh
source "$(dirname "$0")/lib.sh"

dbs=("$@"); [ ${#dbs[@]} -gt 0 ] || dbs=("${MIGRATE_DATA_DBS[@]}")
problems=0

columns() { # SIDE DB -> "table.column data_type nullable max_length", byte-sorted (collations differ between 5.7 and 8.0), without Flyway / SKIP_TABLES
  local skip="'$FLYWAY_TABLE'" t
  for t in ${SKIP_TABLES:-}; do skip+=",'$t'"; done
  q "$1" "$2" "select concat(table_name, '.', column_name, ' ', data_type, ' null=', is_nullable, ' len=',
                 ifnull(character_maximum_length, '-'))
               from information_schema.columns c join information_schema.tables t using (table_schema, table_name)
               where table_schema = database() and table_type = 'BASE TABLE' and table_name not in ($skip)
               order by 1" | LC_ALL=C sort
}

for db in "${dbs[@]}"; do
  echo "################ $db"
  for side in SRC TGT; do
    echo "== $side $(describe_conn "$side" "$db")"
    q "$side" "$db" "select concat('server ', version(), ', character_set_server=', @@character_set_server,
                       ', database charset=', @@character_set_database, ', lower_case_table_names=', @@lower_case_table_names,
                       ', time_zone=', @@time_zone)"
    q "$side" "$db" "select concat('sql_mode=', @@sql_mode)"
    if [ "$side" = SRC ]; then
      # Database Migration Service (continuous) needs the binary log in ROW format with FULL row images (and a
      # replication user); without them only the mysqldump path is possible.
      q "$side" "$db" "select concat('log_bin=', @@log_bin, ', binlog_format=', @@binlog_format, ', binlog_row_image=',
                         @@binlog_row_image, ', gtid_mode=', @@gtid_mode, ', server_id=', @@server_id)"
    fi
    printf '%-32s %10s %10s  %s\n' table rows size_mb collation
    while read -r t; do
      rows=$(q "$side" "$db" "select count(*) from \`$t\`")
      q "$side" "$db" "select concat(rpad('$t', 32, ' '), ' ', lpad('$rows', 10, ' '), ' ',
                         lpad(round((data_length + index_length) / 1048576, 2), 10, ' '), '  ', table_collation)
                       from information_schema.tables where table_schema = database() and table_name = '$t'"
    done < <(tables "$side" "$db")
  done

  echo "== schema: source columns vs target columns"
  if diff_out=$(diff <(columns SRC "$db") <(columns TGT "$db")); then
    echo "same tables and columns ($(columns SRC "$db" | wc -l) columns)"
  else
    sed -e 's/^</  only on source:/' -e 's/^>/  only on target:/' <<<"$diff_out" | grep 'only on' || true
    echo "SCHEMA DIFFERS for $db: fix the Flyway baseline or, after review, list obsolete tables in SKIP_TABLES"
    problems=$((problems + 1))
  fi

  echo "== target Flyway history"
  if has_table TGT "$db" "$FLYWAY_TABLE"; then
    q TGT "$db" "select concat_ws(' ', installed_rank, version, description, type, if(success, 'success', 'FAILED'))
                 from $FLYWAY_TABLE order by installed_rank"
  else
    echo "none: start the GKE deployment once (Flyway applies V1), then scale it to 0, before copy.sh load"
  fi

  echo "== sessions connected to the target database (must be none during the load)"
  q TGT "$db" "select concat(user, '@', substring_index(host, ':', 1), ' ', command, ' ', time, 's')
               from information_schema.processlist where db = database() and id <> connection_id()" || true
done

[ "$problems" = 0 ] || exit 1
