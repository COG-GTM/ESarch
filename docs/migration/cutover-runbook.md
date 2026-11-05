# Axon Trader: cutover runbook

Procedures for phase p6 (*Cut over and retire TAS*) of [tas-gke-mapping.md](tas-gke-mapping.md). Each section is one
plan step. Nothing here has been run against TAS or a GCP project yet; what has been run is stated per section.

## s6.1 Copy the event store and read models to Cloud SQL

Human decision: existing TAS history (users, portfolios, orders, the Axon event store) moves to GKE. Both databases
are copied during the cutover write freeze with [`tools/migrate-data/`](../../tools/migrate-data/README.md):

| TAS (SVC-1, SVC-2) | Cloud SQL (`modules/backing-services`, MySQL 8.0) | Contents |
|---|---|---|
| `enginedb` | database `enginedb`, user `trading-engine` | Axon `domain_event_entry`, `snapshot_event_entry`, `saga_entry`, `association_value_entry`, `token_entry`, `hibernate_sequence` |
| `appdb` | database `appdb`, user `trader-app` | Its Axon tables plus the query-side views (`*_view`, `item_entry`, `orderentry_*`, `portfolio_item_*`) |

Only rows are copied. The schema on Cloud SQL is the Flyway V1 baseline (s3.2), so `ddl-auto=validate` in the
`kubernetes` profile checks the copy against the entities on the first start, and the tables keep Cloud SQL's
`utf8mb4` defaults (the TAS tables are whatever p.mysql defaulted to; the rehearsal source is `latin1`).

### Before the freeze

1. **Confirm what is on TAS, and protect it.** On TAS the ESarch-conf `cloud` profile sets `ddl-auto=update`
   (CFG-2/CFG-3 in [tas-inventory.md](tas-inventory.md)), so restarts keep the data; `create` only applies to a run
   without the Config Server. Still, from now until cutover: no `cf restage` / `cf push` of either app and no change
   to ESarch-conf without a fresh backup (`cf` service backup of both p.mysql instances, or a `copy.sh dump`).
2. **Get read access to both p.mysql instances** from a host that can also reach Cloud SQL: a service key per
   instance (`cf create-service-key <instance> migrate-data`), and either `cf ssh` port forwarding through an app
   container or a jump host on the TAS network. Needs the TAS owner (OPEN-2). The service-key user is enough: `copy.sh dump` needs only
   `SELECT` (`--single-transaction` takes no table locks and the dump skips triggers and routines).
3. **Prepare Cloud SQL.** `infra/terraform` applied (s2.3), `cloudsql-grants.sh` run, then deploy both apps once to
   GKE so Flyway applies V1 to the empty databases, then scale both Deployments to 0. `copy.sh load` refuses to run
   unless `flyway_schema_history` shows V1 succeeded and no other session is connected.
4. **Preflight against the real source**: `tools/migrate-data/preflight.sh`. It must say `same tables and columns`
   for both databases. TAS has run `ddl-auto=update` for years, so it may have tables or columns that the
   entities no longer map (e.g. from older versions); those show up as `only on source`. Decide per table with the
   owner: add it to the baseline in a Flyway V2 if the app needs it, or list it in `SKIP_TABLES` after confirming
   nothing reads it. Do not edit V1.
5. **Initial copy and timing.** Take a full `copy.sh all` + `verify.sh` into a staging Cloud SQL (s6.2) from a TAS
   backup or a live `--single-transaction` dump (consistent, read-only, no locks). Its `timings.tsv` sizes the freeze
   (below). With DMS (next section) this step becomes the continuous migration job instead.

### During the freeze

| # | Step | Command / check |
|---|---|---|
| 1 | Stop writes on TAS: stop the traffic, then both apps | `cf stop trader-app`, `cf stop trading-engine` (service instances stay up) |
| 2 | Make sure no trade is in flight | the RabbitMQ `trades` queue is empty before stopping `trading-engine`, and both event counts no longer change |
| 3 | Preflight, both databases | `tools/migrate-data/preflight.sh` |
| 4 | Final copy (`TARGET_WIPE=yes` if the target holds a previous rehearsal copy) | `tools/migrate-data/copy.sh all` |
| 5 | Verify: every line `OK`, `0 mismatches` | `tools/migrate-data/verify.sh` |
| 6 | Start GKE on the copy | scale `trading-engine`, then `trader-app` up; logs show `Schema ... is up to date` and no `SchemaManagementException` |
| 7 | Smoke test (s6.3): log in as an existing user, the portfolio and transactions match TAS, place a trade | |
| 8 | Keep the dump files on the encrypted host until the rollback window closes, then delete them | `rm -rf target/migrate-data` |

Rollback before step 6: start the TAS apps again; nothing was written on TAS. After step 6 the GKE side has new
events that TAS does not have; rolling back means losing them, or a reverse copy into TAS that these
tools do not do yet (`copy.sh load` insists on a Flyway-managed target). s6.2 decides which and rehearses it.

### Alternative: Database Migration Service

DMS (MySQL → Cloud SQL for MySQL, continuous) shortens the freeze to "stop writes, wait for zero replication lag,
promote", because the bulk copy happens before the freeze. Not rehearsed: there is no GCP project, and DMS cannot run
against the local stand-ins. What it needs from TAS, all to be confirmed with the TAS owner:

- **Network path** from the DMS service to each p.mysql instance: IP allowlist, reverse SSH tunnel or VPC peering.
  p.mysql instances normally sit on the TAS service network with no route from Google; if that cannot be opened,
  use the mysqldump path above.
- **Source settings** (`preflight.sh` prints them): `log_bin=1`, `binlog_format=ROW`, `binlog_row_image=FULL`,
  binlog retention long enough for the initial load, a unique `server_id`, and GTID recommended. p.mysql exposes
  some of these as plan settings only; the TAS owner must check whether they can be changed without a restart.
- **A replication user** on each instance with the privileges the DMS "configure your source" page lists for MySQL
  (replication, `SELECT`, `SHOW VIEW`, `EXECUTE`, `TRIGGER`, `RELOAD`; check the current page when setting it up).
- **Destination**: DMS migrates the source schema as-is (Hibernate `ddl-auto=update` DDL, `latin1`), not the Flyway
  baseline, and there is no `flyway_schema_history`, whether it creates the destination or uses an existing one. After promotion:
  run `preflight.sh` against the promoted instance and the baseline in a scratch database to diff the schema, then
  let Flyway baseline it (`baseline-on-migrate=true`, version 1, already in `application-kubernetes.properties`)
  and only start the apps if `validate` passes. Terraform's `modules/backing-services` then has to import or point
  at the promoted instance instead of creating its own (s2.3 follow-up).
- **Sequence**: create connection profiles and the migration job (full dump + CDC) days before; monitor lag; in the
  freeze stop the TAS apps (steps 1-2 above), wait for lag 0, run `verify.sh` with `TGT_*` pointing at the DMS
  replica, promote, start GKE.

### Freeze sizing (input to s6.2)

Measured by `tools/migrate-data/rehearse.sh` on this repo's stand-ins (one VM, local Docker, no network between
source and target):

| Seed rounds | `enginedb` rows / dump | `appdb` rows / dump | dump (s) | load (s) | `copy.sh all` (s) | `verify.sh` (s) | freeze start → both apps healthy on the copy (s) |
|---|---|---|---|---|---|---|---|
| 300 | 6,350 / 4.7 MB | 2,607 / 0.3 MB | 0.1 + 0.1 | 0.4 + 0.4 | 4 | 4 | 85 |
| 2,000 | 42,050 / 31.2 MB | 16,887 / 1.8 MB | 0.3 + 0.1 | 2.4 + 0.4 | 5 | 6 | 55 |

`copy.sh all` includes the target checks and the row counts; "freeze start → healthy" covers preflight, copy,
verify, a fresh RabbitMQ and both JVM starts with Flyway `validate`, and is dominated by the JVM starts.

The copy itself scales with the dump size (here the load ran at about 13 MB/s, the dump much faster); the
real number has to come from the staging copy of TAS data in step 5 above, where the dump crosses the network
from TAS to Cloud SQL. Freeze budget = stop TAS apps (≈1 min) + drain check (≈1 min) + `preflight.sh` + `copy.sh`
measured on staging × 2 (headroom) + `verify.sh` + GKE start (≈2 min per app, readiness probes) + smoke test
(≈5 min). s6.2 confirms the total on staging and sets the announced window from it.

### What has been run

- `tools/migrate-data/rehearse.sh` locally and in CI (`migrate-data` job in `.github/workflows/java.yml`): MySQL 5.7
  source with both apps on the `local` profile (`ddl-auto=update`, as TAS) seeded through the buy/sell API, MySQL
  8.0 target (TLS required, per-app users) with Flyway V1 applied by the `kubernetes` profile, then preflight,
  copy, verify (all checks match), both apps started on the copy with `validate`, the query API identical to the
  source, and a new trade executed on the copied event store.
- **Not run, still owed:** a copy of real TAS data, a staging run on Cloud SQL, DMS. These need TAS access and a
  GCP project (s6.2).
