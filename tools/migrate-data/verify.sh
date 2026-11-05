#!/usr/bin/env bash
# Compares the TAS source (SRC_*) with the Cloud SQL target (TGT_*) for enginedb and appdb, read-only on both sides.
# Checks per database:
#   tables     same set of base tables (the target's flyway_schema_history and SKIP_TABLES excluded)
#   rows       row count of every table
#   checksum   order-independent checksum of every row of every table (all columns; text compared as utf8mb4,
#              so a latin1 source and a utf8mb4 target compare equal when the characters are the same)
#   event store, on domain_event_entry / snapshot_event_entry: max(global_index), number of aggregates and a digest
#              of every aggregate's max(sequence_number)
# Prints one line per check and exits 1 if any check differs. Connection variables: see lib.sh.
# Usage: tools/migrate-data/verify.sh [enginedb|appdb ...]
# shellcheck source=tools/migrate-data/lib.sh
source "$(dirname "$0")/lib.sh"

dbs=("$@"); [ ${#dbs[@]} -gt 0 ] || dbs=("${MIGRATE_DATA_DBS[@]}")
checks=0 mismatches=0

report() { # db check source target
  local status=OK
  checks=$((checks + 1))
  if [ "$3" != "$4" ]; then status=MISMATCH; mismatches=$((mismatches + 1)); fi
  printf '%-9s %-8s %-52s %-44s %-44s\n' "$status" "$1" "$2" "$3" "$4"
}

# Expression hashing one row: every column hex-encoded (text first converted to utf8mb4), NULL as the literal NULL,
# which cannot collide with hex output. Built from the source's columns and evaluated on both sides by name.
row_expr() {
  local side=$1 db=$2 table=$3 exprs
  exprs=$(q "$side" "$db" "select group_concat(case
        when data_type in ('char','varchar','tinytext','text','mediumtext','longtext','enum','set')
          then concat('ifnull(hex(convert(\`', column_name, '\` using utf8mb4)),''NULL'')')
        when data_type in ('binary','varbinary','tinyblob','blob','mediumblob','longblob','bit','tinyint','smallint','mediumint','int','bigint')
          then concat('ifnull(hex(\`', column_name, '\`),''NULL'')')
        else concat('ifnull(hex(cast(\`', column_name, '\` as char)),''NULL'')')
      end order by column_name separator ', ')
      from information_schema.columns where table_schema = database() and table_name = '$table'")
  printf "md5(concat_ws('|', %s))" "$exprs"
}

# XOR of both 64-bit halves of each row's md5, so the result does not depend on row order or collation. BIT_XOR
# is 0 on no rows; no COALESCE around it, which turns the unsigned result into a DECIMAL/DOUBLE and loses bits.
xor_md5() { # inner select producing column h
  printf "select concat(count(*), ' ', lpad(hex(bit_xor(cast(conv(substr(h, 1, 16), 16, 10) as unsigned))), 16, '0'), lpad(hex(bit_xor(cast(conv(substr(h, 17, 16), 16, 10) as unsigned))), 16, '0')) from (%s) x" "$1"
}

both() { # db sql -> sets SRC_OUT / TGT_OUT
  SRC_OUT=$(q SRC "$1" "$2"); TGT_OUT=$(q TGT "$1" "$2")
}

printf '%-9s %-8s %-52s %-44s %-44s\n' STATUS DB CHECK SOURCE TARGET
for db in "${dbs[@]}"; do
  log "verify $db: source $(describe_conn SRC "$db"), target $(describe_conn TGT "$db")"
  src_tables=$(tables SRC "$db" | paste -sd ' ')
  tgt_tables=$(tables TGT "$db" | paste -sd ' ')
  report "$db" "tables ($(wc -w <<<"$src_tables") on source)" "$(md5sum <<<"$src_tables" | cut -c1-12)" "$(md5sum <<<"$tgt_tables" | cut -c1-12)"
  [ "$src_tables" = "$tgt_tables" ] || { log "source tables: $src_tables"; log "target tables: $tgt_tables"; }

  for t in $src_tables; do
    has_table TGT "$db" "$t" || { report "$db" "$t: present" yes no; continue; }
    both "$db" "select count(*) from \`$t\`"
    report "$db" "$t: rows" "$SRC_OUT" "$TGT_OUT"
    sql=$(xor_md5 "select $(row_expr SRC "$db" "$t") h from \`$t\`")
    both "$db" "$sql"
    report "$db" "$t: checksum" "${SRC_OUT#* }" "${TGT_OUT#* }"
  done

  for t in "${EVENT_TABLES[@]}"; do
    if [[ " $src_tables " != *" $t "* ]] || ! has_table TGT "$db" "$t"; then continue; fi
    if [ "$t" = domain_event_entry ]; then
      both "$db" "select coalesce(max(global_index), 0) from domain_event_entry"
      report "$db" "$t: max(global_index)" "$SRC_OUT" "$TGT_OUT"
    fi
    sql=$(xor_md5 "select md5(concat(hex(convert(aggregate_identifier using utf8mb4)), ':', max(sequence_number))) h from \`$t\` group by aggregate_identifier")
    both "$db" "$sql"
    report "$db" "$t: aggregates" "${SRC_OUT%% *}" "${TGT_OUT%% *}"
    report "$db" "$t: per-aggregate max(sequence_number)" "${SRC_OUT#* }" "${TGT_OUT#* }"
  done
done

echo "$checks checks, $mismatches mismatches"
[ "$mismatches" = 0 ] || exit 1
