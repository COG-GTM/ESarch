# Axon Trader application configuration on Kubernetes

`trader-app` and `trading-engine` run with `SPRING_PROFILES_ACTIVE=kubernetes`
(`<app>/src/main/resources/application-kubernetes.properties`). That profile replaces the TAS Config Server
`cloud` profile (ESarch-conf) and the `VCAP_SERVICES` bindings; see `docs/migration/tas-gke-mapping.md`
(CHG-4 to CHG-9, CHG-12).

| Source | Object | Keys |
| --- | --- | --- |
| ConfigMap (non-secret) | `<app>-config` (`<app>/configmap.yaml`) | `SPRING_PROFILES_ACTIVE`, `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`, `SPRING_RABBITMQ_HOST`, `SPRING_RABBITMQ_PORT`, `SPRING_RABBITMQ_USERNAME`, `SPRING_RABBITMQ_VIRTUAL_HOST`, `EUREKA_DEFAULT_ZONE` |
| Secret Manager → ExternalSecret | `<app>-secrets` (`<app>/externalsecret.yaml`, SecretStore `gcp-sm-<app>`) | `SPRING_DATASOURCE_PASSWORD` (`trader-app-db-password` / `trading-engine-db-password`), `SPRING_RABBITMQ_PASSWORD` (`rabbitmq-password`) |
| Image (vendored ESarch-conf `cloud` values) | `application-kubernetes.properties` | Hikari timeouts and leak detection, `MySQL5InnoDBDialect`, `use-new-id-generator-mappings`, logging levels. Override any of them from the ConfigMap with relaxed binding (`LOGGING_LEVEL_COM_ZAXXER_HIKARI=INFO`, `SPRING_DATASOURCE_HIKARI_MAXIMUMPOOLSIZE=5`, ...) |

The connection properties have no defaults in the profile: a missing variable stops the app at startup instead of
falling back to the embedded H2 database. The `DB_HOST`, `DB_USER` and `RABBITMQ_HOST` values in the ConfigMaps are
placeholders for the Helm chart (s3.5).

## Command routing (Eureka)

Axon's `DistributedCommandBus` (`axon-distributed-commandbus-springcloud` 3.3.3) routes each command to one pod with
a consistent-hash ring built from Spring Cloud DiscoveryClient instances; every pod publishes its command-handling
capabilities in its own instance metadata. On TAS the registry was the SCS Service Registry (`p-service-registry`).
On Kubernetes it is the repo's own Eureka, `discovery-server` (s3.3 decision, mapping OPEN-5 option A), so routing
works unchanged with `axon.distributed.spring-cloud.fallback-to-http-get=false`:

- `discovery-server/`: Deployment (one replica, `Recreate`), ClusterIP Service `discovery-server:8761` and the
  NetworkPolicies Axon needs on top of the platform's default-deny-ingress (apps -> Eureka on 8761, app pod -> app pod
  on 8080 for `/spring-command-bus-connector/command`). The Helm chart (s3.5) takes these over and sets the image.
- Both apps use `spring-cloud-starter-netflix-eureka-client` (the SCS registry starter and BOM are gone), register
  their pod IP (`eureka.instance.prefer-ip-address=true`) at `EUREKA_DEFAULT_ZONE`, renew every 5 s and expire after
  15 s; `discovery-server` runs with self-preservation off, a 5 s eviction pass and no read-only response cache. A pod
  that shuts down cleanly deregisters at once; a crashed pod leaves every ring within about 20-25 s, during which
  commands routed to it fail rather than run twice.

`ci/kind/verify-axon-routing.sh` proves it on kind: two replicas of each app, buy/sell orders handled exactly once,
and routing that survives killing a trading-engine pod.

## Schema

Flyway owns both schemas (`<app>/src/main/resources/db/migration`, `V1__baseline_schema.sql` generated from the
current entity model, including the Axon event store, snapshot, saga, association and token tables). Hibernate runs
with `ddl-auto=validate`, so a pod restart never drops data and a schema that drifts from the entities fails startup.
`spring.flyway.baseline-on-migrate=true` lets a database copied from TAS (tables present, no `flyway_schema_history`)
start at V1 without re-running it. Only the `local` profile still uses `ddl-auto=create`. New schema changes go in a
new `V<n>__<description>.sql`; never edit an applied migration.

## Probes and metrics

Spring Boot 2.0 has no liveness/readiness health groups, so both probes use `/actuator/health`. Startup takes about
40-60 s on a laptop (Flyway, Hibernate validation, Axon processors), so give the probes room:

```yaml
envFrom:
  - configMapRef:
      name: trader-app-config
  - secretRef:
      name: trader-app-secrets
ports:
  - name: http
    containerPort: 8080
readinessProbe:
  httpGet: {path: /actuator/health, port: http}
  initialDelaySeconds: 45
  periodSeconds: 10
  failureThreshold: 6
livenessProbe:
  httpGet: {path: /actuator/health, port: http}
  initialDelaySeconds: 120
  periodSeconds: 20
  timeoutSeconds: 5
  failureThreshold: 6
```

`/actuator/health` includes the database and RabbitMQ checks, so the liveness `failureThreshold` is generous to avoid
restarting pods during a short broker or database blip. Prometheus scrapes `/actuator/prometheus` on the same port
(every metric carries `application=<spring.application.name>`). The profile exposes only `health`, `info`,
`prometheus` and, on `trader-app`, `data-initializer` (used by the seed Job). `/actuator/**` stays cluster-internal
(mapping CHG-12).

## Local check

`ci/local/verify-kubernetes-profile.sh` starts both jars against `docker-compose.yml` with only these variables
(`env -i`), checks Flyway, health and Prometheus, places orders, restarts both apps and diffs orders, portfolios and
event-store counts before and after. `ESARCH_RUNTIME=image` does the same with the Jib images (`esarch/<app>:latest`), listening on 8080 inside the container as in the pod, which is the port `infra/k8s/platform/monitoring.yaml` scrapes.
