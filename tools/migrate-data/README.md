# tools/migrate-data

Copies the two TAS MySQL databases into Cloud SQL for the cutover (plan step s6.1, human decision: copy the event
store and the read models). The procedure, the DMS alternative and the freeze sizing are in
[docs/migration/cutover-runbook.md](../../docs/migration/cutover-runbook.md#s61-copy-the-event-store-and-read-models-to-cloud-sql).

| Database | Owner | Contents |
|---|---|---|
| `enginedb` | `trading-engine` | Axon JPA event store (`domain_event_entry`, `snapshot_event_entry`), sagas (`saga_entry`, `association_value_entry`), `token_entry`, `hibernate_sequence` |
| `appdb` | `trader-app` | Its own Axon tables plus the query-side views (`*_view`, `item_entry`, `orderentry_*`, `portfolio_item_*`) |

| Script | What it does | Writes to |
|---|---|---|
| `preflight.sh [db ...]` | Read-only inventory of both sides: server version, charsets, `sql_mode`, binlog settings (for DMS), rows / size / collation per table, a source-vs-target column diff, the target's Flyway history and the sessions connected to it. Exits 1 if the columns differ | nothing |
| `copy.sh [all\|dump\|load] [db ...]` | `dump`: `mysqldump --single-transaction` of the rows only (the schema is the target's Flyway V1), read-only on the source. `load`: refuses unless Flyway V1 is applied and nobody is connected, empties the tables (`TARGET_WIPE=yes` when they already hold rows) and loads the dump. Records seconds / rows / bytes | `$DUMP_DIR` (default `target/migrate-data/dump`, git-ignored) |
| `verify.sh [db ...]` | Source vs target: table set, rows and an order-independent checksum of every column of every table, `max(global_index)`, number of aggregates and per-aggregate `max(sequence_number)` for both event tables. Exits 1 on any mismatch | nothing |
| `rehearse.sh` | The whole cutover on this machine with `rehearsal/compose.yml` (MySQL 5.7 TAS stand-in, MySQL 8.0 Cloud SQL stand-in, RabbitMQ): seed through the buy/sell API, Flyway on the target, freeze, preflight / copy / verify, start the apps on the copy, compare the query API and trade on the copy | `target/migrate-data/rehearsal` |

## Connections

Per side (`SRC` = TAS, `TGT` = Cloud SQL) and per database, because on TAS each database is its own p.mysql service
instance: `<SIDE>_<DB>_HOST|PORT|USER|PASSWORD|NAME|SSL_MODE`, falling back to `<SIDE>_HOST` etc. (`lib.sh`).
`<SIDE>_<DB>_NAME` defaults to `enginedb` / `appdb`; p.mysql names the database `service_instance_db`.
`<SIDE>_SSL_MODE` defaults to `REQUIRED`. Passwords are read from the environment and passed to the clients only as `MYSQL_PWD`; never put them in a file in
the repo or on a command line. The client is the local `mysql` / `mysqldump` 8.0, or the same tools from an image
with `MYSQL_CLIENT_IMAGE=mysql:8.0.46`.

```bash
# TAS: credentials from a service key (cf create-service-key <instance> migrate-data; cf service-key ...), read in a shell
export SRC_ENGINEDB_HOST=... SRC_ENGINEDB_USER=... SRC_ENGINEDB_NAME=service_instance_db SRC_ENGINEDB_SSL_MODE=REQUIRED
read -rs SRC_ENGINEDB_PASSWORD && export SRC_ENGINEDB_PASSWORD
# same for SRC_APPDB_*
# Cloud SQL: through the Auth Proxy on 127.0.0.1:3306, which encrypts the hop itself (to the private IP directly,
# leave TGT_SSL_MODE at its default REQUIRED). The workload users from Secret Manager.
export TGT_HOST=127.0.0.1 TGT_SSL_MODE=DISABLED TGT_ENGINEDB_USER=trading-engine TGT_APPDB_USER=trader-app
export "TGT_ENGINEDB_PASSWORD=$(gcloud secrets versions access latest --secret=trading-engine-db-password)"
export "TGT_APPDB_PASSWORD=$(gcloud secrets versions access latest --secret=trader-app-db-password)"

tools/migrate-data/preflight.sh && tools/migrate-data/copy.sh all && tools/migrate-data/verify.sh
```

`SKIP_TABLES="t1 t2"` leaves tables out of the copy and the checks, for tables that Hibernate `ddl-auto=update`
left on TAS but the Flyway baseline does not have. Only after a human has reviewed what is in them.

## Rehearsal

```bash
JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 ./mvnw -B -DskipTests package
JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 SEED_ROUNDS=300 tools/migrate-data/rehearse.sh
```

Needs Docker, Java 8, `mysql` / `mysqldump` 8.0 clients, `jq` and `curl`, and ports 3316, 3317, 5672, 8080, 8081
and 8761 free. `KEEP_STACK=1` leaves the containers running afterwards. The CI job `migrate-data` in
`.github/workflows/java.yml` runs it on every change.
