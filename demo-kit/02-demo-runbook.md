# Demo Runbook: TAS → GKE with Axon Trader

Audience: a platform or application team running Tanzu Application Service / Cloud Foundry that has
been told to move to GKE. The point of the demo is not "Kubernetes YAML exists" — it is that the
migration is *inventoried, mapped, staged, and verified*, and that each stage lands as a reviewable PR.

Total runtime: ~20 minutes for the walkthrough, ~35 if you re-run a migration step live.

---

## 0. Before the room joins

| Check | Command |
| --- | --- |
| Baseline builds | `export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 && mvn -DskipTests package` |
| kind cluster up, pods ready | `kubectl get pods` |
| UI reachable | open the Ingress/port-forward URL, place one trade |

Have open in tabs: the TAS manifests, `demo-kit/01-migration-assessment.md`, the containerize PR, the
Helm PR, and the running UI.

---

## 1. Establish the "before" state (3 min)

Show that this is a real TAS application, not a Kubernetes sample wearing a costume:

- `trading-engine/manifest.yml` — `java_buildpack`, `health-check-type: port`, `instances: 1`, and
  five bound services: `enginedb`, `rabbit`, `config`, `registry`.
- `deploy-backend.sh` — `cf push --random-route`, then `cf add-network-policy` in both directions.
- `ci/pipeline.yml` — Concourse with a `put: push-to-pcf` step.
- Search the repo for `spring.datasource` and find **nothing**. The credentials live in
  `VCAP_SERVICES`, injected by the platform at runtime.

The line that lands: *nobody on this team wrote down how this app gets its database. The platform did
it. That is exactly what a migration has to make explicit.*

---

## 2. The assessment, not the guess (4 min)

Walk `demo-kit/01-migration-assessment.md`. Emphasise three things:

1. **Every row cites a file.** The scope is auditable — no "we think it uses RabbitMQ".
2. **It names the one real architectural decision** (§3.4): Axon's `DistributedCommandBus` routes
   commands through Spring Cloud `DiscoveryClient`. On TAS that is the SCS Service Registry tile.
   Phase 1 self-hosts the Eureka server already in the repo; ripping Eureka out for Kubernetes-native
   discovery is a *code change to command routing* and gets its own phase and its own evidence.
3. **It names what YAML cannot fix** (§4): the event store is the system of record, so `enginedb`
   needs a cutover data migration; and trading-engine scale-out is bounded by Axon event-processor
   semantics, not by replica count.

Anyone can generate a Dockerfile. Knowing that the exchange/queue semantics in
`AmqpConfiguration.java` mean Pub/Sub is not a drop-in for CloudAMQP is the actual work.

---

## 3. Phase 1 — containerize (4 min)

Open the containerize PR. What replaced the buildpacks:

| Buildpack behaviour | What now does it |
| --- | --- |
| JRE selection + memory calculator | multi-stage Dockerfile, JRE 8 runtime stage, container-aware heap, non-root |
| `staticfile_buildpack` + `Staticfile` `pushstate: enabled` | nginx image with SPA history fallback |
| `VCAP_SERVICES` datasource/Rabbit wiring | explicit `SPRING_DATASOURCE_*` / `SPRING_RABBITMQ_*` |
| `management.cloudfoundry.enabled=true` | set to `false`; actuator now feeds probes |

The nginx detail worth pausing on: `trader-app-ui/src/utils/config.js` hardcodes a map of
`cfapps.io` hostnames, falling back to `''` — same origin — for anything it doesn't recognise. So
serving the API under the same origin through nginx means **the React source needs no change at all**
and no rebuild per environment. Migrations get cheaper when you read the code before rewriting it.

Evidence: images build, the stack comes up locally, both backends report `UP`, the UI drives real API
calls.

When changing `docker/mysql/init/01-databases.sql`, run
`docker compose down -v` before bringing the stack back up. MySQL init scripts
run only for a new data volume; retaining the old volume can leave `enginedb`
missing and make trading-engine fail to connect.

---

## 4. Phase 2 — Helm chart and GKE resources (5 min)

Open the Helm PR and go mapping-by-mapping, because each one is a question the room will ask:

| They ask | Show them |
| --- | --- |
| "Where did our bound services go?" | ConfigMap (the SCS `*-cloud.yml` content) + Secrets |
| "How does the route work?" | Ingress in front of the UI |
| "What about `health-check-type: port`?" | readiness/liveness on `/actuator/health` — an upgrade: TAS only checked the port was open |
| "`timeout: 120`?" | `startupProbe` with the same budget |
| "Our network policies?" | NetworkPolicy pair replacing the two `cf add-network-policy` calls |
| "`cf scale`?" | HPA — on trader-app only, and say why |
| "Is this really our production database?" | values switch: in-cluster MySQL for kind, Cloud SQL + Auth Proxy sidecar + Workload Identity for GKE |

Then show it running on kind and place a trade in the UI. Pods-ready is not the claim; a completed
buy through the CQRS path is.

---

## 5. Phase 3 — delivery (2 min)

`ci/pipeline.yml`'s `put: push-to-pcf` becomes: build image → push to Artifact Registry → `helm
upgrade`. Provided for both Cloud Build and GitHub Actions. Same three verbs, different platform.

---

## 6. Close: what this says about the engagement (2 min)

- The work arrived as **staged, reviewable PRs**, each independently verifiable — not one 4,000-line
  drop.
- The risks that remain (event-store cutover, Java 8 / Boot 2.0.3 out of support, Eureka removal) are
  **written down and scoped out**, not quietly skipped.
- Phase 1 deliberately did not modernize the framework. Changing the platform and the runtime at once
  makes failures impossible to attribute — and this is the estate-wide pattern: dozens of apps,
  identical mapping, one playbook.

---

## Likely questions

**"Would you really keep Eureka on Kubernetes?"** Not long-term. Phase 1 keeps it so the platform
change is isolated; Phase 2 replaces it with `spring-cloud-kubernetes`. Since it changes Axon command
routing, it needs its own test evidence.

**"Why not Pub/Sub instead of RabbitMQ?"** Axon's AMQP event distribution depends on exchange/queue
semantics declared in `AmqpConfiguration.java` (exchange `trading-engine-events`, queue `trades`,
`#` binding, publisher acks). Pub/Sub means a new Axon transport — an application change, not a
migration step.

**"How long for our estate?"** Per app, the mapping is largely mechanical once the assessment exists.
The genuinely per-app work is the platform-injected configuration and any discovery/messaging
coupling. The cutover — data migration and DNS — is the long pole, and it is an operational schedule,
not an engineering one.
