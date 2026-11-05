# TAS → GKE Migration Assessment: Axon Trader

Baseline: the Pivotal/VMware "Axon Trader" event-sourcing reference architecture, built to run on
Pivotal Application Service (TAS) with Pivotal Web Services marketplace services.

This document is the inventory and target-state mapping the migration work is driven from. Every row
in the mapping tables points at a file in this repository, so the scope is auditable rather than
asserted.

## 1. What is deployed on TAS today

Three `cf push` units, one Maven multi-module build, one npm build:

| CF app | Source | Artifact | Buildpack | Manifest |
| --- | --- | --- | --- | --- |
| `esrefarch-demo-trading-engine` | `trading-engine/` | `target/trading-engine.jar` | `java_buildpack` | `trading-engine/manifest.yml` |
| `esrefarch-demo-trader-app` | `trader-app/` | `target/trader-app.jar` | `java_buildpack` | `trader-app/manifest.yml` |
| `esrefarch-demo-trader-ui` | `trader-app-ui/` | `build/` (CRA output) | `staticfile_buildpack` | `trader-app-ui/manifest.yml` |

`discovery-server/` is a fourth Maven module (Spring Cloud Netflix Eureka server, port 8761). It is
**not** pushed to TAS — on TAS its role is filled by the Spring Cloud Services Service Registry tile.
It becomes relevant again on Kubernetes (see §3.4).

### Brokered services the apps bind to

From the manifests and `pave.sh`:

| Bound service | Marketplace offering | Consumed by |
| --- | --- | --- |
| `appdb` | ClearDB MySQL | trader-app (JPA projections) |
| `enginedb` | ClearDB MySQL | trading-engine (Axon event store) |
| `rabbit` | CloudAMQP RabbitMQ | both — Axon event distribution, exchange `trading-engine-events`, queue `trades` |
| `config` | Spring Cloud Services Config Server | both — backed by the git repo `pivotalsoftware/ESarch-conf` via `config-server-setup.json` |
| `registry` | Spring Cloud Services Service Registry (Eureka) | both — Axon `DistributedCommandBus` routing |

### Platform behaviour the app currently depends on

| Dependency | Where it shows up |
| --- | --- |
| Buildpack-injected JRE + memory calculator | no Dockerfile anywhere in the repo |
| `VCAP_SERVICES` auto-reconfiguration of `DataSource` / `ConnectionFactory` | no `spring.datasource.*` or `spring.rabbitmq.*` in `application.properties`; credentials are never in the app |
| `cloud` Spring profile activated by the buildpack | config files named `trader-app-cloud.yml` / `trading-engine-cloud.yml` in the config repo |
| CF actuator integration | `management.cloudfoundry.enabled=true` in both services |
| CF routes on `*.cfapps.io` | `--random-route` in `deploy-backend.sh`; UI's API base URL points at `esrefarch-demo-trader-app.cfapps.io` |
| Container-to-container networking policy | `cf add-network-policy` calls in `deploy-backend.sh` |
| Direct registration for direct app-to-app calls | `spring.cloud.services.registrationMethod=direct` |
| `health-check-type: port` | both backend manifests — a TCP check, not an application health check |
| Concourse + the `cf` resource for delivery | `ci/pipeline.yml`, `ci/tasks/*.yml`, `put: push-to-pcf` |
| `TRUST_CERTS: api.run.pivotal.io` | all three manifests — a foundation-specific TLS workaround |

Scale/reliability posture today: `instances: 1` for every app, no autoscaler configuration in the repo.

## 2. Migration principles

1. **Lift, then shift.** Phase 1 keeps the application's runtime contract (Java 8, Spring Boot 2.0.x,
   Axon 3.3, Eureka-based command routing) and replaces only the platform underneath it. Framework
   modernization is a separate, later track — mixing the two makes failures impossible to attribute.
2. **Nothing the platform used to inject may stay implicit.** Every credential, URL and profile that
   TAS supplied through `VCAP_SERVICES` becomes explicit configuration in a ConfigMap or Secret.
3. **Each phase must be independently verifiable** on a local `kind` cluster before it targets GKE.

## 3. Target state on GKE

### 3.1 Build and packaging

`java_buildpack` → container image. Two viable options, both kept in scope for the demo:

- **Paketo buildpacks** (`pack build`) — the direct descendant of the CF Java buildpack, so JRE
  selection and the memory calculator behave the way operators already expect. Least surprising for a
  TAS platform team.
- **Multi-stage Dockerfile** — explicit and dependency-free, easier to review in a PR.

`staticfile_buildpack` → nginx image serving the CRA `build/` output, with `try_files` to reproduce
`pushstate: enabled`.

### 3.2 Data services

| TAS | GKE |
| --- | --- |
| ClearDB MySQL (`appdb`, `enginedb`) | Cloud SQL for MySQL, one database per service, reached via the Cloud SQL Auth Proxy sidecar with Workload Identity. Local/kind: a MySQL StatefulSet. |
| CloudAMQP (`rabbit`) | RabbitMQ on GKE (RabbitMQ Cluster Operator). Pub/Sub is *not* a drop-in: Axon's AMQP event distribution relies on exchange/queue semantics. |

Because the event store is the system of record, the cutover plan needs a data-migration step for
`enginedb` (dump/restore, or replicate then flip) — called out here as a known gap rather than solved
by manifests.

### 3.3 Configuration and secrets

| TAS | GKE |
| --- | --- |
| SCS Config Server backed by `ESarch-conf` | the `*-cloud.yml` content rendered into a ConfigMap mounted as `application-cloud.yml`; `SPRING_PROFILES_ACTIVE=cloud` set explicitly |
| `VCAP_SERVICES` credential injection | Secrets → `SPRING_DATASOURCE_*`, `SPRING_RABBITMQ_*` |
| `management.cloudfoundry.enabled=true` | set to `false`; actuator is exposed to probes instead |
| `TRUST_CERTS` | removed |

Self-hosting Spring Cloud Config Server on GKE stays an option, but for a two-service app a ConfigMap
removes a component rather than relocating it.

### 3.4 Service discovery and command routing

This is the migration's one genuine architectural decision. Axon's `DistributedCommandBus` routes
commands through Spring Cloud's `DiscoveryClient`, which on TAS is the SCS Service Registry.

- **Phase 1 (recommended): run the bundled Eureka.** `discovery-server/` already exists in this repo;
  deploying it as a Deployment + Service and pointing both services at it keeps application code
  untouched. Replaces a platform tile with a workload we own.
- **Phase 2 (optional, shown as a follow-up): Kubernetes-native discovery** via
  `spring-cloud-kubernetes`, deleting Eureka entirely in favour of Services and cluster DNS. This is a
  code change to command routing and deserves its own PR and its own test evidence.

`cf add-network-policy` → NetworkPolicy resources granting trader-app ↔ trading-engine traffic.

### 3.5 Routing, health, scaling

| TAS | GKE |
| --- | --- |
| CF route on `*.cfapps.io`, `--random-route` | Ingress (or Gateway API) with host rules. The UI needs no change: `ApiConfig()` in `trader-app-ui/src/utils/config.js` falls back to an empty base URL — same origin — for any host outside its hardcoded `cfapps.io` map, so nginx reverse-proxies `/query` and `/command` to the trader-app Service |
| `health-check-type: port` | `readinessProbe`/`livenessProbe` on `/actuator/health` — an actual application health signal, which is an improvement, not a like-for-like swap |
| `timeout: 120` | `startupProbe` with an equivalent budget |
| `instances: 1` | `replicas` + HPA on CPU. Note: horizontal scaling of the trading-engine is bounded by Axon's event-processor semantics; the HPA is applied to trader-app first. |
| `cf logs` | stdout → Cloud Logging |
| Actuator + CF metrics | Managed Service for Prometheus scraping actuator |

### 3.6 Delivery

Concourse (`ci/pipeline.yml`) `put: push-to-pcf` → build image, push to Artifact Registry, deploy the
Helm chart. Provided as both Cloud Build and GitHub Actions so the demo works for either audience.

## 4. Known gaps and risks

- **TAS-specific dependencies still resolve, for now.** The `io.pivotal.spring.cloud` SCS starters
  (`2.0.1.RELEASE`) and Spring Cloud Finchley do resolve from public Maven mirrors today — verified by
  a full `mvn -DskipTests package` and `mvn test` (171 tests, 0 failures) on JDK 8. They stay in the
  build after phase 1 even though nothing on GKE consumes the SCS integration; removing them belongs
  to the modernization track.
- **Java 8 / Spring Boot 2.0.3 are both out of support.** Phase 1 containerizes them as-is; the
  modernization track (Boot 3.x, Java 17/21, Axon 4) is deliberately out of scope here.
- **Event store migration** for `enginedb` is a cutover activity, not a manifest.
- **Trading-engine scale-out** is constrained by event-processor design, independent of Kubernetes.

## 5. Verification plan

| Phase | Evidence required |
| --- | --- |
| Baseline (done) | `mvn -DskipTests package` on JDK 8 produces `trader-app.jar`, `trading-engine.jar`, `discovery-server-0.0.1-SNAPSHOT.jar`; `mvn test` passes 171 tests; `npm ci && npm run build` succeeds on Node 20 |
| Containerize | all three images build; each container starts and serves `/actuator/health` (backend) or `/` (UI) against local MySQL + RabbitMQ |
| Deploy to Kubernetes | `helm install` on `kind` reaches all-pods-ready; UI loads through the Ingress; a trade placed in the UI is accepted and the resulting projection is visible |
| CI | pipeline builds and pushes images and renders the chart |
