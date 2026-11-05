# Axon Trader: TAS → GKE mapping

Plan step `s1.2` (phase *Inventory the TAS footprint*). One row per item of [`tas-inventory.md`](tas-inventory.md) (`s1.1`), using its IDs, plus one row per open item in its §10. Each row names the GKE target, the plan step that owns the change (phases p2-p6) and the files that change. §1 lists the code and config edits behind those rows, so the owning step can work straight from it.

Paths are relative to the repo root. `Lx` means line numbers on `master` at `5778983`. Files under `deploy/` and `.github/workflows/` (other than `terraform.yml`) don't exist yet. They are the paths this mapping proposes for the steps that create them. The step that owns a row may pick another path, but must then update this file.

## 0. Owner steps

| Phase | Step | Ticket title |
|---|---|---|
| p2 | s2.1 | Write Terraform for the GCP foundation |
| p2 | s2.2 | Provision GKE clusters for staging and prod |
| p2 | s2.3 | Provision MySQL and RabbitMQ backing services |
| p2 | s2.4 | Wire logging, metrics and alerting |
| p3 | s3.1 | Build container images for the Java services |
| p3 | s3.2 | Replace TAS bindings with Kubernetes config |
| p3 | s3.3 | Replace the service registry for Axon routing |
| p3 | s3.4 | Serve the React UI from nginx |
| p3 | s3.5 | Package the app as Helm charts |
| p4 | s4.1 | Build, scan and publish images in CI |
| p4 | s4.2 | Deploy to staging on every main merge |
| p4 | s4.3 | Gate production releases behind approval |
| p5 | s5.1 | Run the functional parity suite on staging |
| p5 | s5.2 | Load test staging at production sizing |
| p5 | s5.3 | Drill failures of pods, broker and database |
| p5 | s5.4 | Review GKE security posture |
| p6 | s6.1 | Copy event store and read models to Cloud SQL |
| p6 | s6.2 | Rehearse cutover and rollback on staging |
| p6 | s6.3 | Cut production traffic over to GKE |
| p6 | s6.4 | Decommission TAS apps and CF tooling |

Where a row has more than one owner, the first one listed does the change and the others depend on it or verify it.

## 1. Code and config changes

Every TAS coupling in the Java code and its config, checked against the source. The `Inventory IDs` column links each change back to the mapping rows in §2-§9.

| # | TAS coupling (verified in code) | Change for GKE | Owner | Files that change | Inventory IDs |
|---|---|---|---|---|---|
| CHG-1 | `spring-cloud-services-starter-service-registry` (`pom.xml` L58-61, BOM `spring-cloud-services-dependencies` 2.0.1.RELEASE at L137-142). It brings the Eureka client that the SCS registry (SVC-4) needs, with CF UAA OAuth2 | Remove the starter and add one of the two discovery options in CHG-3. Remove the SCS BOM once CHG-4 is done too | s3.3 | `pom.xml` | SVC-4, BND-4, BND-8, NET-3 |
| CHG-2 | `@EnableDiscoveryClient` on `TradingEngineApplication` (`trading-engine/.../TradingEngineApplication.java` L12, L15). `trader-app` has no annotation and registers through starter auto-configuration | Keep the annotation (it is a generic Spring Cloud Commons annotation and works with either CHG-3 option). Nothing to add to `trader-app` | s3.3 | none (verify only) | SVC-4 |
| CHG-3 | `axon-distributed-commandbus-springcloud` 3.3.3 (`pom.xml` L109-113, artifact at L111) with `axon.distributed.enabled=true` and `axon.distributed.spring-cloud.fallback-to-http-get=false` (`trader-app/src/main/resources/application.properties` L5, L8; `trading-engine/src/main/resources/application.properties` L9-10). Axon's `SpringCloudCommandRouter` publishes each node's command-handling capabilities as **DiscoveryClient instance metadata**, and `trader-app` routes commands to `trading-engine` through it. `TraderAggregateDataInitializer` L45, L75 calls `commandRouter.findDestination(...)` and refuses to seed data if no node is found | **Option A (default, smallest change):** run APP-4 `discovery-server` in-cluster and swap CHG-1 for `spring-cloud-starter-netflix-eureka-client` (Finchley.RELEASE, already the BOM at `pom.xml` L32). Eureka keeps metadata updates working, so `fallback-to-http-get=false` can stay. Set `eureka.client.service-url.defaultZone=http://discovery-server:8761/eureka/`. **Option B:** Spring Cloud Kubernetes discovery (a release that supports Boot 2.0 / Finchley, to be pinned in s3.3) with `axon.distributed.spring-cloud.fallback-to-http-get=true`. Kubernetes endpoints carry no writable metadata, so Axon falls back to `GET /message-routing-information` on each pod. This needs RBAC to read `endpoints`/`services`/`pods` in the namespace. s3.3 makes the call (OPEN-5) and documents it here | s3.3 (s3.5 deploys APP-4 or the RBAC) | `pom.xml`, both `src/main/resources/application.properties`, `discovery-server/` (option A), `deploy/helm/` (s3.5) | SVC-4, APP-4, NET-1, NET-2, NET-4, OPEN-5 |
| CHG-4 | `spring-cloud-services-starter-config-client` (`pom.xml` L62-65), used by both apps through `spring.application.name` in each `bootstrap.properties` L1 to pull CFG-1…CFG-3 from SVC-5 | Remove the starter. Ship the effective `cloud` profile values (CFG-2/CFG-3) inside the repo as `application-gke.properties` per app, with environment-specific values and secrets as env vars from a ConfigMap and Secrets (Spring relaxed binding: `SPRING_DATASOURCE_URL`, etc.). No Config Server on GKE unless OPEN-3 decides otherwise | s3.2 | `pom.xml`, `trader-app/src/main/resources/application-gke.properties` (new), `trading-engine/src/main/resources/application-gke.properties` (new), `deploy/helm/` (s3.5) | SVC-5, BND-3, BND-7, CFG-1, CFG-2, CFG-3, OPEN-3 |
| CHG-5 | `management.cloudfoundry.enabled=true` (`trading-engine/.../application.properties` L7, `trader-app/.../application.properties` L17), the Apps Manager actuator integration | Delete the property. It does nothing off CF | s3.2 | both `src/main/resources/application.properties` | APP-1, APP-2 |
| CHG-6 | `spring.cloud.services.registrationMethod=direct` (`trader-app/.../application.properties` L20, `trading-engine/.../application.properties` L17), which registers container IP:port instead of the route | Delete the property. Option A replaces it with `eureka.instance.prefer-ip-address=true` (registers the pod IP, the same effect). Option B needs nothing, since Kubernetes endpoints are pod IPs already | s3.3 | both `src/main/resources/application.properties` | NET-4 |
| CHG-7 | MySQL credentials from `VCAP_SERVICES`. No JDBC URL anywhere in the repo or ESarch-conf; on TAS the buildpack auto-reconfiguration builds the `DataSource` (inferred, inventory §3). `mysql-connector-java` is on the runtime classpath (`pom.xml` L77-81) and H2 is the fallback (L71-75) | Explicit `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME` from the ConfigMap and `SPRING_DATASOURCE_PASSWORD` from Secret Manager (`trading-engine-db-password`, `trader-app-db-password`, already declared in `infra/terraform/` by s2.1), synced into a Kubernetes Secret or mounted with the Secret Manager CSI driver. Connection through the Cloud SQL Auth Proxy sidecar (the workload service accounts already have `roles/cloudsql.client`) or private IP. Keep the CFG-2/CFG-3 Hikari settings. Keep H2 off in GKE profiles | s3.2 (s2.3 creates the databases and users) | `application-gke.properties` (both apps), `deploy/helm/` (s3.5) | SVC-1, SVC-2, BND-1, BND-5, OPEN-7 |
| CHG-8 | `spring.jpa.hibernate.ddl-auto=create` and `spring.jpa.generate-ddl=true` in both `bootstrap.properties` (`trader-app/src/main/resources/bootstrap.properties` L5-6, `trading-engine/src/main/resources/bootstrap.properties` L6-7). On TAS the ESarch-conf `cloud` profile overrides it with `update` (CFG-2/CFG-3 L25). Without the Config Server and the `cloud` profile, `create` drops and recreates every table on start, **including the Axon JPA event store, sagas and token store** | Must change before any GKE environment holds data. `application-gke.properties` sets `spring.jpa.hibernate.ddl-auto=validate` once the schema is managed by a migration tool (Flyway or Liquibase, baselined from the TAS schema in s6.1), or `update` as a stop-gap that matches TAS today. Also change the in-repo default in both `bootstrap.properties` to `update` (or remove it), so that a missing profile can never wipe a database | s3.2 (s6.1 baselines the schema) | both `src/main/resources/bootstrap.properties`, both `application-gke.properties`, `pom.xml` if a migration tool is added | CFG-2, CFG-3, SVC-1, SVC-2, OPEN-6 |
| CHG-9 | RabbitMQ from `VCAP_SERVICES` (inferred, inventory §3). Both apps set `axon.amqp.exchange=trading-engine-events` and `axon.amqp.transaction-mode=publisher_ack` (`trader-app/.../application.properties` L11-12, `trading-engine/.../application.properties` L12-13). The apps declare their own AMQP topology: `trading-engine` declares the exchange (`trading-engine/.../AmqpConfiguration.java` L14), `trader-app` declares the exchange, the durable `trades` queue and the binding (`trader-app/.../AmqpConfiguration.java` L21-28) | Explicit `SPRING_RABBITMQ_HOST`, `SPRING_RABBITMQ_PORT`, `SPRING_RABBITMQ_USERNAME`, `SPRING_RABBITMQ_VIRTUAL_HOST` from the ConfigMap and `SPRING_RABBITMQ_PASSWORD` from Secret Manager (`rabbitmq-password`, already declared by s2.1). The broker user needs configure/write/read on its vhost so the apps can keep declaring their topology. Keep the `axon.amqp.*` properties unchanged | s3.2 (s2.3 runs the broker) | `application-gke.properties` (both apps), `deploy/helm/` (s3.5) | SVC-3, BND-2, BND-6, OPEN-7 |
| CHG-10 | `TRUST_CERTS: api.run.pivotal.io` in all three manifests | Drop. It only served the SCS client libraries removed by CHG-1/CHG-4 | s3.2 | manifests deleted in s6.4 | NET-3 |
| CHG-11 | UI API host map hard-coded to `*.cfapps.io` (`trader-app-ui/src/utils/config.js` L1-10), used as `API_ROOT` in `actions/home.js` L11, `actions/company.js` L22, `actions/portfolio.js` L12, `containers/CompanyContainer.js` L8. Unknown hosts get `''` (relative URLs) | Serve UI and API on the same host through the Ingress (`/` → UI, `/command`, `/query` → `trader-app`), so `ApiConfig()` returns `''` and the browser calls relative paths. Replace the `cfapps.io` entries with `localhost` → `http://localhost:8080` for local runs (as README §3 already suggests). No per-environment rebuild of the bundle | s3.4 | `trader-app-ui/src/utils/config.js` | RTE-5, RTE-6, NET-5, OPEN-1, OPEN-2 |
| CHG-12 | Actuator fully exposed and permit-all: `management.endpoints.web.exposure.include=*` (both `application.properties`) and `SecurityConfig.java` in each app. The Axon cluster endpoints `POST /spring-command-bus-connector/command` and `GET /message-routing-information` (Axon 3.3.3 `SpringHttpCommandBusConnector`, `SpringCloudHttpBackupCommandRouter`) are served by the same apps. On TAS all of these were reachable on the public routes | The Ingress exposes only `/command/**` and `/query/**` of `trader-app` and the UI. `/actuator/**` (including `POST /actuator/data-initializer`), `/spring-command-bus-connector/**` and `/message-routing-information` stay cluster-internal (ClusterIP Services plus NetworkPolicy). Narrow `management.endpoints.web.exposure.include` to `health,info,prometheus` in the GKE profile if s2.4 uses Prometheus scraping. App-level auth is out of scope for the platform move, so s5.4 records it as a finding | s3.5 (s5.4 reviews) | `deploy/helm/`, both `application-gke.properties` | APP-1, APP-2, RTE-1, RTE-2, RTE-4, NET-5 |
| CHG-13 | `java_buildpack` builds and runs both jars (`manifest.yml` `buildpacks`), Java 8 (`pom.xml` L30) | Multi-stage Dockerfile per Java app: Maven 3 / JDK 8 build stage, JRE 8 runtime stage, non-root user, `SPRING_PROFILES_ACTIVE=gke`. The buildpack set container memory flags itself; set them explicitly in the image or chart instead | s3.1 | `trading-engine/Dockerfile`, `trader-app/Dockerfile`, `discovery-server/Dockerfile` (option A) | APP-1, APP-2, APP-4 |
| CHG-14 | `staticfile_buildpack` with `Staticfile` `directory: visible`, `pushstate: enabled` (`trader-app-ui/Staticfile` L1-2) | nginx image serving `build/`: `try_files $uri /index.html` for pushstate, no directory listing (`directory: visible` is dropped on purpose) | s3.4 | `trader-app-ui/Dockerfile`, `trader-app-ui/nginx.conf` (new); `trader-app-ui/Staticfile` and `trader-app-ui/manifest.yml` deleted in s6.4 | APP-3 |

## 2. Applications

| ID | TAS item | GKE target | Owner | Files that change |
|---|---|---|---|---|
| APP-1 | `esrefarch-demo-trading-engine`, `java_buildpack`, 1 instance, `port` health check, 120 s start timeout | Deployment `trading-engine` in namespace `axon-trader` (the KSA name s2.1 already binds to `<env>-trading-engine`), image from CHG-13, 1 replica to match TAS (scaling is tested in s5.2), readiness and liveness probes on `/actuator/health` port 8080 and a startup probe allowing 120 s. ClusterIP Service on 8080 | s3.1 image, s3.5 chart | `trading-engine/Dockerfile`, `deploy/helm/` (CHG-5, CHG-12, CHG-13) |
| APP-2 | `esrefarch-demo-trader-app`, same settings | Deployment `trader-app` in `axon-trader`, same probes, ClusterIP Service on 8080 and the Ingress backend for `/command` and `/query` | s3.1 image, s3.5 chart | `trader-app/Dockerfile`, `deploy/helm/` (CHG-5, CHG-12, CHG-13) |
| APP-3 | `esrefarch-demo-trader-ui`, `staticfile_buildpack`, `build/` | Deployment `trader-ui` (nginx, CHG-14), ClusterIP Service, Ingress backend for `/` | s3.4 image, s3.5 chart | `trader-app-ui/Dockerfile`, `trader-app-ui/nginx.conf`, `trader-app-ui/src/utils/config.js` (CHG-11) |
| APP-4 | `discovery-server`, not pushed to TAS, local stand-in for SVC-4 | Option A: Deployment + ClusterIP Service `discovery-server:8761` (single replica, self-preservation settings tuned in s3.3). Option B: not deployed; the module stays as a local dev aid or is removed | s3.3 (s3.1 image if option A) | `discovery-server/src/main/resources/application.properties`, `discovery-server/Dockerfile`, `deploy/helm/` |

## 3. Service instances

| ID | TAS item | GKE target | Owner | Files that change |
|---|---|---|---|---|
| SVC-1 | `enginedb` (MySQL: `trading-engine` Axon JPA event store, sagas, token store, entities) | Cloud SQL for MySQL, private IP on the s2.1 private services access range, database and user for `trading-engine`, password in Secret Manager `trading-engine-db-password`. Data copy from TAS in s6.1 | s2.3 (s6.1 data) | `infra/terraform/modules/` (new Cloud SQL module) and `infra/terraform/envs/*/main.tf`; app side CHG-7, CHG-8 |
| SVC-2 | `appdb` (MySQL: `trader-app` event store and projections) | Same Cloud SQL instance (separate database and user) or a second instance, decided in s2.3. Password `trader-app-db-password` | s2.3 (s6.1 data) | same as SVC-1 |
| SVC-3 | `rabbit` (RabbitMQ, exchange `trading-engine-events`, queue `trades`) | RabbitMQ on GKE (RabbitMQ Cluster Operator, persistent volume) or a managed RabbitMQ reachable from the VPC, decided in s2.3. User password in `rabbitmq-password`. No topology to pre-create (CHG-9) | s2.3 | `infra/terraform/` or `deploy/` (broker manifests); app side CHG-9 |
| SVC-4 | `registry` (SCS Service Registry, Eureka, backs Axon command routing) | Option A: APP-4 Eureka in-cluster. Option B: Spring Cloud Kubernetes discovery + `fallback-to-http-get=true`. See CHG-3 | s3.3 | CHG-1, CHG-2, CHG-3, CHG-6 |
| SVC-5 | `config` (SCS Config Server, Git backend ESarch-conf) | No Config Server. Effective values vendored into `application-gke.properties`, environment values in a ConfigMap, secrets from Secret Manager (CHG-4) | s3.2 | CHG-4 |

## 4. Service bindings

| ID | TAS binding | GKE replacement | Owner | Files that change |
|---|---|---|---|---|
| BND-1 | `trading-engine` → `enginedb` | `SPRING_DATASOURCE_*` env vars on the `trading-engine` Deployment (CHG-7), Auth Proxy sidecar or private IP, Workload Identity KSA `axon-trader/trading-engine` → GSA `<env>-trading-engine` | s3.2, s3.5 | `trading-engine/src/main/resources/application-gke.properties`, `deploy/helm/` |
| BND-2 | `trading-engine` → `rabbit` | `SPRING_RABBITMQ_*` env vars (CHG-9) | s3.2, s3.5 | same |
| BND-3 | `trading-engine` → `config` | Removed. Config comes from the image profile plus ConfigMap (CHG-4) | s3.2 | `pom.xml`, `deploy/helm/` |
| BND-4 | `trading-engine` → `registry` | Option A: Eureka client pointed at `discovery-server`. Option B: Kubernetes discovery with a Role/RoleBinding for the KSA (CHG-3) | s3.3 | `pom.xml`, `trading-engine/src/main/resources/application.properties`, `deploy/helm/` |
| BND-5 | `trader-app` → `appdb` | As BND-1 for `trader-app` (GSA `<env>-trader-app`) | s3.2, s3.5 | `trader-app/src/main/resources/application-gke.properties`, `deploy/helm/` |
| BND-6 | `trader-app` → `rabbit` | As BND-2 | s3.2, s3.5 | same |
| BND-7 | `trader-app` → `config` | As BND-3 | s3.2 | `pom.xml`, `deploy/helm/` |
| BND-8 | `trader-app` → `registry` | As BND-4 | s3.3 | `pom.xml`, `trader-app/src/main/resources/application.properties`, `deploy/helm/` |

The stale `cf us esrefarch-demo-trader-ui config` in `teardown.sh` L71 has no GKE counterpart; it goes with OPS-6.

## 5. Config Server property sources

| ID | TAS item | GKE target | Owner | Files that change |
|---|---|---|---|---|
| CFG-1 | ESarch-conf `application.yml` (empty) | Nothing to carry over | s3.2 | none |
| CFG-2 | `trading-engine/trading-engine-cloud.yml` (logging levels, Hikari, `MySQL5InnoDBDialect`, `ddl-auto=update`, `use-new-id-generator-mappings=true`) | Copy into `trading-engine/src/main/resources/application-gke.properties`, with `ddl-auto` per CHG-8. Profile `gke` replaces `cloud` | s3.2 | `trading-engine/src/main/resources/application-gke.properties` |
| CFG-3 | `trader-app/trader-app-cloud.yml` (as CFG-2, `show-sql=true`, `your.host.is`) | Copy into `trader-app/src/main/resources/application-gke.properties`. Set `show-sql=false` for production (it logs every statement), and drop `your.host.is` unless the UI or an endpoint reads it (no code reads it at `5778983`) | s3.2 | `trader-app/src/main/resources/application-gke.properties` |
| CFG-4 | `trader-app-ui/application.properties` (not consumed at runtime) | Nothing to carry over. The UI API host is handled by CHG-11 | s3.4 | none |

## 6. Routes and host names

| ID | TAS item | GKE target | Owner | Files that change |
|---|---|---|---|---|
| RTE-1 | random route for `trading-engine` | None public. `trading-engine` gets only a ClusterIP Service: nothing outside the cluster calls it except the smoke tests, which run in-cluster or through `kubectl port-forward` (CI-5) | s3.5 | `deploy/helm/` |
| RTE-2 | random route for `trader-app` | Ingress path rules `/command`, `/query` → `trader-app:8080` on the environment host (CHG-12) | s3.5 | `deploy/helm/` |
| RTE-3 | random route for `trader-ui` | Ingress default path `/` → `trader-ui` on the same host | s3.5 | `deploy/helm/` |
| RTE-4 | default `*.cfapps.io` routes used by Concourse, `ci/run-tests.sh`, README, `http-api.http` | One host per environment (for example `axon-trader.staging.<domain>`, `axon-trader.<domain>`), GKE Ingress with a static global IP and a Google-managed certificate, DNS record in the team's zone. All hard-coded `cfapps.io` references replaced: CI in CI-5…CI-7/CI-17, docs in OPS rows, `http-api.http` uses a `{{host}}` variable | s3.5 (s4.2 staging DNS, s6.3 production DNS) | `deploy/helm/`, `ci/run-tests.sh`, `http-api.http`, `README.md` |
| RTE-5 | UI → API host map in `config.js` | Same-origin routing (CHG-11) | s3.4 | `trader-app-ui/src/utils/config.js` |
| RTE-6 | `axontrader.cfapps.io` (unconfirmed vanity host) | No GKE equivalent unless OPEN-1 confirms an owner. Remove the key from `config.js` in CHG-11 | s3.4 (decision OPEN-1) | `trader-app-ui/src/utils/config.js`, `README.md` L5 |

## 7. Network policies and platform networking

| ID | TAS item | GKE target | Owner | Files that change |
|---|---|---|---|---|
| NET-1 | C2C `trader-app` → `trading-engine` (TCP 8080) | NetworkPolicy allowing `trader-app` pods → `trading-engine` pods on 8080 (Axon `/spring-command-bus-connector/command`, and `/message-routing-information` with option B). Requires a GKE cluster with network policy enforcement (Dataplane V2), set in s2.2 | s3.5 (s2.2 enables enforcement) | `deploy/helm/`, `infra/terraform/` GKE module (s2.2) |
| NET-2 | C2C `trading-engine` → `trader-app` (TCP 8080) | Mirror NetworkPolicy. Plus egress to Cloud SQL / Auth Proxy, RabbitMQ (5672), `discovery-server` (8761, option A) or the Kubernetes API (option B), and DNS, with a default-deny policy for the namespace | s3.5 | `deploy/helm/` |
| NET-3 | `TRUST_CERTS` | Removed (CHG-10) | s3.2 | none after s6.4 |
| NET-4 | `registrationMethod=direct` | Pod IP registration (CHG-6) | s3.3 | both `application.properties` |
| NET-5 | Cross-origin browser → API calls (`@CrossOrigin("*")`) | Same-origin through the Ingress (CHG-11), so CORS is no longer needed. Leave `@CrossOrigin` in place in p3 for rollback safety; s5.4 decides whether to narrow it | s3.4, s5.4 | `CommandController.java`, `QueryController.java` (only if s5.4 narrows CORS) |
| NET-6 | Long-lived SSE `/query/subscribe/order-book/{id}` through the TAS router | GKE Ingress (external Application Load Balancer) with a `BackendConfig` on the `trader-app` Service setting `timeoutSec` well above the expected stream lifetime (the default backend timeout is 30 s). Load test the stream in s5.2 | s3.5 (s5.2 verifies) | `deploy/helm/` |

## 8. Delivery: Concourse

| ID | TAS item | GKE target | Owner | Files that change |
|---|---|---|---|---|
| CI-1 | `just-build-it` manual gate | Dropped. Builds run on every PR and merge; production promotion is the manual gate (s4.3) | s4.1 | `ci/pipeline.yml` deleted in s6.4 |
| CI-2 | `build-trading-engine` → `push-to-pcf` | GitHub Actions job: `mvn verify`, Docker build, Trivy (or equivalent) scan, push to Artifact Registry with WIF auth (s2.1 outputs `ci_workload_identity_provider`, `ci_service_account`) | s4.1 | `.github/workflows/build.yml` (new) |
| CI-3 | `build-trader-app` → `push-to-pcf` | Same job matrix entry for `trader-app` (runs the Spring Cloud Contract tests) | s4.1 | `.github/workflows/build.yml` |
| CI-4 | `build-trader-ui` → `push-to-pcf` | Same workflow: `npm ci && npm run build`, nginx image, scan, push | s4.1 | `.github/workflows/build.yml` |
| CI-5 | `smoke-test-trading-engine` | Post-deploy job after `helm upgrade` on staging: health `UP` through `kubectl port-forward` or an in-cluster Job (no public route, RTE-1) | s4.2 | `.github/workflows/deploy-staging.yml` (new), `ci/tasks/smoke-test-trading-engine.sh` (URL from env, unchanged logic) |
| CI-6 | `smoke-test-trader-app` | Post-deploy job against the staging Ingress host | s4.2 | `.github/workflows/deploy-staging.yml` |
| CI-7 | `e2e-test` | Post-deploy job against staging, then the fuller parity suite | s4.2 (s5.1 extends) | `.github/workflows/deploy-staging.yml`, `ci/tasks/e2e-test-both-sides.sh` |
| CI-8 | `manualtrigger` `time` resource | Dropped (`workflow_dispatch` covers manual runs) | s4.1 | none |
| CI-9 | `source-code` git resource with deploy key | Native checkout in GitHub Actions; the deploy key is not needed | s4.1 | none |
| CI-10 | `push-to-pcf` `cf` resource, `slack-alert` resource | `helm upgrade --install` with the `<env>-ci-deployer` account (`roles/container.developer`) via WIF; GitHub environments `staging` and `production` (required reviewers on production). Slack notification through a GitHub Action with the webhook as a repository secret | s4.2, s4.3 | `.github/workflows/deploy-staging.yml`, `.github/workflows/deploy-prod.yml` (new) |
| CI-11 | `build-trading-engine.sh` | Replaced by the Dockerfile build stage (CHG-13). Fix of the `${OLDPATH}` echo (L6) not needed once deleted | s4.1 (deleted s6.4) | `ci/tasks/build-trading-engine.{sh,yml}` |
| CI-12 | `build-trader-app.sh` | As CI-11 | s4.1 (deleted s6.4) | `ci/tasks/build-trader-app.{sh,yml}` |
| CI-13 | `build-trader-ui.sh` (copies `manifest.yml`, `Staticfile`) | Replaced by the UI Dockerfile (CHG-14) | s4.1 (deleted s6.4) | `ci/tasks/build-trader-ui.{sh,yml}` |
| CI-14 | `smoke-test-trading-engine.sh` | Kept as a script, called from CI-5 with `URL` set to the GKE target | s4.2 | none, or image tag only in the `.yml` |
| CI-15 | `smoke-test-trader-app.sh` | Kept, called from CI-6 | s4.2 | none |
| CI-16 | `e2e-test-both-sides.sh` | Kept, called from CI-7. `uiURL` and `appURL` become the same host; the `/actuator/*` calls (health, info, `data-initializer`) need an in-cluster or port-forward path because CHG-12 keeps actuator off the Ingress | s4.2 (s5.1 re-enables the commented create-company checks L106-131) | `ci/tasks/e2e-test-both-sides.sh` |
| CI-17 | `ci/run-tests.sh` (always overwrites URLs with `*.cfapps.io`) | Fix the unquoted `[ -n $engineURL ]` tests (L5, L11, L17) to `[ -z "${engineURL:-}" ]` and default to `localhost` so it serves local and GKE runs | s4.2 | `ci/run-tests.sh` |
| CI-18 | `ci/tasks/archive/*` (Gradle era, unused) | Drop | s6.4 | `ci/tasks/archive/` deleted |

## 9. cf CLI operator scripts

| ID | TAS item | GKE target | Owner | Files that change |
|---|---|---|---|---|
| OPS-1 | `pave.sh` (create services on PWS) | `terraform apply` of `infra/terraform/envs/<env>` (s2.1-s2.3) | s2.3 (deleted s6.4) | `pave.sh` |
| OPS-2 | `bigpave-pws.sh` | As OPS-1 | s2.3 (deleted s6.4) | `bigpave-pws.sh` |
| OPS-3 | `bigpave-pcf.sh` | As OPS-1 | s2.3 (deleted s6.4) | `bigpave-pcf.sh` |
| OPS-4 | `deploy-backend.sh` (build, push with random routes, add C2C policies) | `helm upgrade --install` from CI (CI-10); local developers use `docker compose` or `helm` against a dev cluster | s4.2 (deleted s6.4) | `deploy-backend.sh` |
| OPS-5 | `deploy-frontend.sh` (needs hand-edited `config.js`) | Same Helm release; no hand edit after CHG-11 | s4.2 (deleted s6.4) | `deploy-frontend.sh` |
| OPS-6 | `teardown.sh` | `helm uninstall` and `terraform destroy` per environment, documented in the runbook. The TAS teardown itself is run once in s6.4 | s6.4 | `teardown.sh` (deleted after use), `README.md` |
| OPS (post-deploy seed) | `curl -X POST <trader-app>/actuator/data-initializer` (README §2) | Helm post-install hook Job or a documented `kubectl port-forward` + `curl`, since `/actuator` stays internal (CHG-12). It requires routing to work (`findDestination`, CHG-3), so it doubles as a check of SVC-4's replacement | s3.5 | `deploy/helm/`, `README.md` |

`README.md` and `config-server-setup.json` describe the TAS path only. s6.4 rewrites the README for GKE and deletes `config-server-setup.json`, every `manifest.yml`, `trader-app-ui/Staticfile`, `ci/pipeline.yml`, `ci/tips.txt` and the OPS scripts.

## 10. Open items from the inventory (§10)

| ID | Inventory §10 item | Resolution in this mapping | Owner | Files that change |
|---|---|---|---|---|
| OPEN-1 | RTE-6 `axontrader.cfapps.io` unconfirmed | Not migrated. If the TAS org owner confirms a vanity host on the live foundation, add it as an extra Ingress host and certificate in s6.3 | s6.3 (needs the TAS org owner) | `deploy/helm/` values only if confirmed |
| OPEN-2 | `cfapps.io` / PWS is gone; live TAS foundation not recorded | All `cfapps.io` references are removed by CHG-11, RTE-4, CI-17 and s6.4. The live foundation's API, org/space and plans must be confirmed before s6.1 (data export) and s6.4 (decommission) | s6.1, s6.4 (needs TAS access) | `docs/migration/` cutover runbook |
| OPEN-3 | ESarch-conf: vendor or keep a Config Server | Vendor (CHG-4). The values are small, static and public; a Config Server would be one more stateful component with no consumer | s3.2 | `application-gke.properties` (both apps) |
| OPEN-4 | `ci/private.yml` values | Not migrated. GitHub Actions uses WIF (no stored GCP keys); the Slack webhook becomes a repository secret; the deploy key is not needed (CI-9). Nothing is committed | s4.1 | `.github/workflows/*` (secret references only) |
| OPEN-5 | SVC-4 replacement | Option A (Eureka in-cluster) is the default for the first cut; option B stays open. s3.3 decides and records the choice in this file | s3.3 | CHG-1, CHG-3, CHG-6 |
| OPEN-6 | `ddl-auto` precedence | CHG-8: explicit `ddl-auto` in the GKE profile and a safe in-repo default; migration tool baselined in s6.1 | s3.2, s6.1 | both `bootstrap.properties`, both `application-gke.properties` |
| OPEN-7 | Runtime credential wiring for SVC-1/2/3 inferred | CHG-7 and CHG-9 make it explicit. s5.1 confirms on staging that both apps use MySQL and RabbitMQ and not the H2 fallback (for example via `/actuator/health` details or the datasource URL in logs) | s3.2, s5.1 | both `application-gke.properties` |

## 11. Coverage check

Every inventory ID has a row: APP-1…4 (§2), SVC-1…5 (§3), BND-1…8 (§4), CFG-1…4 (§5), RTE-1…6 (§6), NET-1…6 (§7), CI-1…18 (§8), OPS-1…6 (§9), and the seven §10 open items (§10). The script below compares the IDs in `tas-inventory.md` with the rows here and must print `unmapped: none`.

```bash
inv=$(grep -oE '\b(APP|SVC|BND|CFG|RTE|NET|CI|OPS)-[0-9]+\b' docs/migration/tas-inventory.md | sort -u)
map=$(grep -oE '^\| (APP|SVC|BND|CFG|RTE|NET|CI|OPS|OPEN)-[0-9]+ ' docs/migration/tas-gke-mapping.md | awk '{print $2}' | sort -u)
missing=$(comm -23 <(echo "$inv") <(echo "$map"))
echo "unmapped: ${missing:-none}"
open=$(grep -cE '^[0-9]+\. \*\*' <(sed -n '/^## 10\./,$p' docs/migration/tas-inventory.md))
rows=$(echo "$map" | grep -c '^OPEN-')
echo "open items: $open, OPEN rows: $rows"
```
