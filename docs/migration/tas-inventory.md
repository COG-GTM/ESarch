# Axon Trader: TAS inventory

Plan step `s1.1` (phase *Inventory the TAS footprint*). This file lists everything Axon Trader takes from Tanzu Application Service (TAS, formerly PCF/PAS and Pivotal Web Services), using only what is in this repo plus the external Config Server repo it points at. The TAS → GKE mapping (`s1.2`) should use the IDs below (`APP-*`, `SVC-*`, `BND-*`, `CFG-*`, `RTE-*`, `NET-*`, `CI-*`, `OPS-*`). The phase gate is met when every ID here maps to a GKE item.

Paths are relative to the repo root. `Lx` means line numbers on `master` at `c6e2f27`.

## 1. Summary

| Category | Count | IDs |
|---|---|---|
| Apps pushed to TAS | 3 | APP-1 … APP-3 |
| Apps not on TAS (local only) | 1 | APP-4 |
| Service instances | 5 | SVC-1 … SVC-5 |
| Service bindings | 8 | BND-1 … BND-8 |
| Config Server property sources | 4 | CFG-1 … CFG-4 |
| Routes / host names | 6 | RTE-1 … RTE-6 |
| Network policies and platform networking | 6 | NET-1 … NET-6 |
| Concourse jobs, resources and tasks | 18 | CI-1 … CI-18 |
| cf CLI operator scripts | 6 | OPS-1 … OPS-6 |

## 2. Applications

| ID | TAS app name | Source module | Buildpack | Artifact (`path`) | Instances | Health check | Start timeout | Env | Source |
|---|---|---|---|---|---|---|---|---|---|
| APP-1 | `esrefarch-demo-trading-engine` | `trading-engine/` (Spring Boot 2.0.3, Java 8, Axon 3.3.3; `spring.application.name=trading-engine`) | `java_buildpack` | `target/trading-engine.jar` | 1 | `port` | 120 s | `TRUST_CERTS: api.run.pivotal.io` | `trading-engine/manifest.yml` L3-16 |
| APP-2 | `esrefarch-demo-trader-app` | `trader-app/` (Spring Boot 2.0.3, Java 8, Axon 3.3.3; `spring.application.name=trader-app`) | `java_buildpack` | `target/trader-app.jar` | 1 | `port` | 120 s | `TRUST_CERTS: api.run.pivotal.io` | `trader-app/manifest.yml` L3-16 |
| APP-3 | `esrefarch-demo-trader-ui` | `trader-app-ui/` (React 16, `react-scripts` 1.1.5, built with `npm run build`) | `staticfile_buildpack` | `build` | 1 | not set (TAS default: `port`) | 120 s | `TRUST_CERTS: api.run.pivotal.io` | `trader-app-ui/manifest.yml` L3-10 |
| APP-4 | not pushed: `discovery-server` | `discovery-server/` (`@EnableEurekaServer`, `server.port=8761`) | none | none | none | none | none | none | `discovery-server/src/main/resources/application.properties` L1, `discovery-server/src/main/java/com/example/discoveryserver/DiscoveryServerApplication.java` L7, `pom.xml` L24 |

Notes:

- **APP-3 static file settings.** `trader-app-ui/Staticfile` sets `directory: visible` (L1) and `pushstate: enabled` (L2). With pushstate on, deep links such as `/dashboard` are served `index.html`, so the React router can handle them. `ci/tasks/build-trader-ui.sh` L14 copies the `Staticfile` into `build/` before the push.
- **APP-4 is not on TAS today.** It has no `manifest.yml`, and no script or Concourse job pushes it. On TAS, the service registry comes from Spring Cloud Services instead (SVC-4, see BND-4/BND-8). APP-4 is only the local stand-in that the README describes ("You'll need Spring Cloud Registry running in the background, see the `discovery-server` folder"). It is still a module in the root `pom.xml`, so `mvn package` builds it.
- **How the Java apps use TAS.** Both apps pull in `spring-cloud-services-starter-service-registry` and `spring-cloud-services-starter-config-client` (`pom.xml` L60, L64; BOM `spring-cloud-services-dependencies` 2.0.1.RELEASE at L139-140). Both set `management.cloudfoundry.enabled=true`, which turns on the Apps Manager actuator integration (`trading-engine/src/main/resources/application.properties` L7, `trader-app/src/main/resources/application.properties` L17). `trading-engine` declares `@EnableDiscoveryClient` (`TradingEngineApplication.java` L15). `trader-app` relies on registry auto-registration from the starter.
- **Public endpoints that matter for routing.** APP-2 serves `/command/**` and `/query/**` with `@CrossOrigin("*")` (`CommandController.java` L32, `QueryController.java` L44). It also serves a Server-Sent Events stream, `GET /query/subscribe/order-book/{id}` (`QueryController.java` L138), which the UI opens with `EventSource` (`trader-app-ui/src/containers/CompanyContainer.js` L44). Both Java apps expose every actuator endpoint (`management.endpoints.web.exposure.include=*`) and permit all requests (`SecurityConfig.java` in each app). APP-2 adds a custom `POST /actuator/data-initializer` (`TraderAggregateDataInitializer.java` L36).

## 3. Service instances

`pave.sh` is the documented path (README §1). `bigpave-pws.sh` is the same thing with paid PWS plans. `bigpave-pcf.sh` targets an enterprise PCF foundation. All three create the same five **instance names**. `teardown.sh` deletes them.

| ID | Instance name | Purpose in Axon Trader | PWS `pave.sh` (offering / plan) | PWS paid `bigpave-pws.sh` | Enterprise PCF `bigpave-pcf.sh` | Deleted by |
|---|---|---|---|---|---|---|
| SVC-1 | `enginedb` | MySQL for `trading-engine`: Axon JPA event store, sagas and token store, plus JPA entities | `cleardb` / `spark` (L64) | `cleardb` / `amp` (L64) | `p.mysql` / `db-small` (L4) | `teardown.sh` L81 |
| SVC-2 | `appdb` | MySQL for `trader-app`: Axon JPA event store and query-side projections | `cleardb` / `spark` (L65) | `cleardb` / `amp` (L65) | `p.mysql` / `db-small` (L5) | `teardown.sh` L80 |
| SVC-3 | `rabbit` | RabbitMQ shared by both apps. Axon AMQP event exchange `trading-engine-events`, `publisher_ack` | `cloudamqp` / `lemur` (L66) | `cloudamqp` / `tiger` (L66) | `p.rabbitmq` / `single-node-3.7` (L6) | `teardown.sh` L77 |
| SVC-4 | `registry` | Spring Cloud Services Service Registry (Eureka). Backs Axon's Spring Cloud distributed command bus | `p-service-registry` / `trial` (L67) | `p-service-registry` / `standard` (L67) | `p-service-registry` / `standard` (L7) | `teardown.sh` L79 |
| SVC-5 | `config` | Spring Cloud Services Config Server. Git backend, see §5 | `p-config-server` / `trial` + `-c config-server-setup.json` (L68) | `p-config-server` / `standard` + `-c config-server-setup.json` (L68) | `p-config-server` / `standard` + `-c config-server-setup.json` (L8) | `teardown.sh` L78 |

Notes:

- The `p-service-registry` and `p-config-server` names in the plan are the marketplace **offerings**. The instance names the apps bind to are `registry` and `config`.
- **SVC-3:** both apps set `axon.amqp.exchange=trading-engine-events` and `axon.amqp.transaction-mode=publisher_ack` (`trader-app/src/main/resources/application.properties` L11-12, `trading-engine/src/main/resources/application.properties` L12-13). `trading-engine` also sets `axon.serializer.events=jackson` (L15).
- **SVC-4:** both apps set `axon.distributed.enabled=true`, `axon.distributed.spring-cloud.fallback-to-http-get=false` and `spring.cloud.services.registrationMethod=direct` (`trader-app/.../application.properties` L5, L8, L20; `trading-engine/.../application.properties` L9-10, L17). With `direct`, each app registers its container IP and port rather than its route, so command-bus traffic between the apps runs over container-to-container networking (NET-1/NET-2).
- **SVC-1, SVC-2, SVC-3 credentials.** No JDBC URL or AMQP URI appears anywhere in this repo or in ESarch-conf. On TAS the bound credentials come from `VCAP_SERVICES`. We infer, without confirming at runtime, that the `java_buildpack` auto-reconfiguration and Spring Cloud Connectors build the `DataSource` and the Rabbit `ConnectionFactory` from those credentials. Off TAS, the apps fall back to the in-memory H2 driver that is on the classpath (`pom.xml` L73, README "Running Axon Trader Locally").
- **Free-plan limits.** README §1 notes that the free plans `pave.sh` uses (`spark`, `lemur`, `trial`) have usage limits, for example a 7-day lifetime on the Spring Cloud Services trial plans.

## 4. Service bindings

| ID | App | Bound instance | Source (bind) | Source (unbind) |
|---|---|---|---|---|
| BND-1 | `esrefarch-demo-trading-engine` | `enginedb` (SVC-1) | `trading-engine/manifest.yml` L11 | `teardown.sh` L74 |
| BND-2 | `esrefarch-demo-trading-engine` | `rabbit` (SVC-3) | `trading-engine/manifest.yml` L12 | `teardown.sh` L73 |
| BND-3 | `esrefarch-demo-trading-engine` | `config` (SVC-5) | `trading-engine/manifest.yml` L13 | `teardown.sh` L70 |
| BND-4 | `esrefarch-demo-trading-engine` | `registry` (SVC-4) | `trading-engine/manifest.yml` L14 | `teardown.sh` L68 |
| BND-5 | `esrefarch-demo-trader-app` | `appdb` (SVC-2) | `trader-app/manifest.yml` L11 | `teardown.sh` L75 |
| BND-6 | `esrefarch-demo-trader-app` | `rabbit` (SVC-3) | `trader-app/manifest.yml` L12 | `teardown.sh` L72 |
| BND-7 | `esrefarch-demo-trader-app` | `config` (SVC-5) | `trader-app/manifest.yml` L13 | `teardown.sh` L69 |
| BND-8 | `esrefarch-demo-trader-app` | `registry` (SVC-4) | `trader-app/manifest.yml` L14 | `teardown.sh` L67 |

Binding matrix:

| App \ instance | `enginedb` | `appdb` | `rabbit` | `registry` | `config` |
|---|---|---|---|---|---|
| `esrefarch-demo-trading-engine` | yes | | yes | yes | yes |
| `esrefarch-demo-trader-app` | | yes | yes | yes | yes |
| `esrefarch-demo-trader-ui` | | | | | not in manifest\* |

\* `trader-app-ui/manifest.yml` has no `services:` block, so the UI is bound to nothing. `teardown.sh` L71 still runs `cf us esrefarch-demo-trader-ui config`. That line is left over from an older binding. It unbinds something that `deploy-frontend.sh` never bound, so it does not count as a binding.

## 5. Config Server backend (SVC-5)

`config-server-setup.json` (L2-5) configures SVC-5 with:

```json
{ "git": { "uri": "https://github.com/pivotalsoftware/ESarch-conf.git", "searchPaths": "{application}" } }
```

- Reachability: the repo is **public** and was cloned for this inventory (`git clone --depth 1`, HEAD `777d7dc12384815f0d2b290381e2c787cf128119`, last commit 2022-03-25). No branch or label is pinned, so the server serves the default branch.
- Resolution: `searchPaths: {application}` maps each client's `spring.application.name` to a folder (`trader-app` and `trading-engine`, set in each app's `src/main/resources/bootstrap.properties` L1). The files are named `<app>-cloud.yml`, so they only apply under the `cloud` Spring profile. We infer that `java_buildpack` activates that profile on TAS; off TAS nothing activates it.

| ID | ESarch-conf file | Served to | Properties |
|---|---|---|---|
| CFG-1 | `application.yml` | every client (all apps, all profiles) | empty file (0 bytes) |
| CFG-2 | `trading-engine/trading-engine-cloud.yml` | `trading-engine`, profile `cloud` | `logging.level`: `org.axonframework=INFO`, `io.pivotal.refarch=DEBUG`, `org.hibernate.SQL=INFO`, `com.zaxxer.hikari=DEBUG`. `spring.datasource.type=com.zaxxer.hikari.HikariDataSource`. `spring.datasource.hikari`: `leakDetectionThreshold=5000`, `connectionTimeout=30000`, `idleTimeout=30000`, `maxLifetime=30000` (`maximumPoolSize` and `minimumIdle` commented out). `spring.jpa`: `generate-ddl=true`, `show-sql=false`, `database-platform=org.hibernate.dialect.MySQL5InnoDBDialect`, `hibernate.ddl-auto=update`, `hibernate.use-new-id-generator-mappings=true` |
| CFG-3 | `trader-app/trader-app-cloud.yml` | `trader-app`, profile `cloud` | Same as CFG-2 except `spring.jpa.show-sql=true`, plus `your.host.is="Allard Buijze"` (demo property) |
| CFG-4 | `trader-app-ui/application.properties` | only a client named `trader-app-ui`. **Not consumed at runtime**: the UI is static files, is not a Spring client and is not bound to `config` | `esrefarch.trader-app.base-url-scheme=http`, `esrefarch.trader-app.base-url=esrefarch-demo-trader-app.cfapps.io`, `REACT_APP_API_ROOT=https://esrefarch-demo-trader-app.cfapps.io`. No code in `trader-app-ui/src` reads `REACT_APP_*`; the API host comes from RTE-5 |

Effect on schema handling: the in-repo `bootstrap.properties` files set `spring.jpa.hibernate.ddl-auto=create` (`trader-app/src/main/resources/bootstrap.properties` L6, `trading-engine/src/main/resources/bootstrap.properties` L7). Remote Config Server sources take precedence over local files by default in Spring Cloud Config. So on TAS the effective value is `update` (CFG-2/CFG-3). Off TAS, without SVC-5, it reverts to `create`, which wipes the schema and the Axon JPA event store on every restart. Any replacement for SVC-5 has to keep `update` or move to managed migrations.

## 6. Routes and host names

| ID | Route / host | How it is created or used | Source |
|---|---|---|---|
| RTE-1 | random route on the shared domain for `esrefarch-demo-trading-engine` | `cf push -f manifest.yml --random-route` | `deploy-backend.sh` L77 |
| RTE-2 | random route on the shared domain for `esrefarch-demo-trader-app` | `cf push -f manifest.yml --random-route` | `deploy-backend.sh` L83 |
| RTE-3 | random route on the shared domain for `esrefarch-demo-trader-ui` | `cf push -f manifest.yml --random-route` | `deploy-frontend.sh` L77 |
| RTE-4 | `esrefarch-demo-trading-engine.cfapps.io`, `esrefarch-demo-trader-app.cfapps.io`, `esrefarch-demo-trader-ui.cfapps.io` (default routes: app name on the PWS shared domain `cfapps.io`) | Concourse `cf` resource pushes with no `--random-route`, so TAS assigns the default route. The same hosts are hard-coded as smoke/e2e targets and sample `private.yml` values | `ci/pipeline.yml` L20-23, L46-49, L72-74; `ci/run-tests.sh` L7, L13, L19; README (`cf apps` output, `private.yml` example); `http-api.http` L13, L26 |
| RTE-5 | UI → API host map in the bundle: `localhost`, `esrefarch-demo-trader-ui.cfapps.io` and `axontrader.cfapps.io` all map to `https://esrefarch-demo-trader-app.cfapps.io` | `HostURLsMapping` in `trader-app-ui/src/utils/config.js` L1-5. `ApiConfig()` (L6-10) resolves it from `window.location.hostname` and returns `''` for unknown hosts. Used as `API_ROOT` in `actions/home.js` L11, `actions/company.js` L22, `actions/portfolio.js` L12 and `containers/CompanyContainer.js` L8. README §3 tells operators to edit this file by hand after each random-route push | `trader-app-ui/src/utils/config.js` |
| RTE-6 | `axontrader.cfapps.io` (claimed vanity host for the public demo, **unconfirmed**) | Appears in RTE-5 and as link *text* in README L5, but that link's target (`[5]`, README L235) is the default UI host `https://esrefarch-demo-trader-ui.cfapps.io/`. **No `cf map-route` / `cf create-route` in the repo**, so whether this route was ever mapped on TAS can't be confirmed from the repo | `trader-app-ui/src/utils/config.js` L4; `README.md` L5, L235 |

The PWS API endpoint `https://api.run.pivotal.io` is hard-coded in every operator script that logs in: OPS-1, OPS-2 and OPS-6 (`export API=` at L20) and OPS-4 and OPS-5 (L28). OPS-3 uses whatever `cf target` is current. It is also the value of `TRUST_CERTS` (NET-3) and the README's example `cf-endpoint`.

## 7. Network policies and platform networking

| ID | Item | Detail | Source |
|---|---|---|---|
| NET-1 | C2C policy `esrefarch-demo-trader-app` → `esrefarch-demo-trading-engine` | `cf add-network-policy esrefarch-demo-trader-app --destination-app esrefarch-demo-trading-engine` (no `--port`/`--protocol`, so the cf CLI defaults apply: TCP 8080) | `deploy-backend.sh` L87 |
| NET-2 | C2C policy `esrefarch-demo-trading-engine` → `esrefarch-demo-trader-app` | `cf add-network-policy esrefarch-demo-trading-engine --destination-app esrefarch-demo-trader-app` (same defaults) | `deploy-backend.sh` L88 |
| NET-3 | `TRUST_CERTS: api.run.pivotal.io` | Set on all three apps. The Spring Cloud Services client libraries read it to trust the CF API / UAA certificate when calling SVC-4/SVC-5. It has no effect on the static UI | `trading-engine/manifest.yml` L15-16, `trader-app/manifest.yml` L15-16, `trader-app-ui/manifest.yml` L9-10 |
| NET-4 | Direct registry registration | `spring.cloud.services.registrationMethod=direct`. Eureka holds container IPs, which only works because of NET-1/NET-2 | `trader-app/src/main/resources/application.properties` L20, `trading-engine/src/main/resources/application.properties` L17 |
| NET-5 | Cross-origin browser → API calls | The UI is served from a different host than the API, so it relies on `@CrossOrigin("*")` on `/command` and `/query` | `trader-app/.../controller/CommandController.java` L32, `.../QueryController.java` L44 |
| NET-6 | Long-lived SSE through the TAS router | `EventSource` to `/query/subscribe/order-book/{id}` on the API route. The replacement ingress or load balancer must allow streaming responses without buffering and with a long idle timeout | `trader-app-ui/src/containers/CompanyContainer.js` L44, `trader-app/.../QueryController.java` L138 |

Teardown verification (README "Cleaning Up") checks `cf network-policies`. `teardown.sh` never removes NET-1/NET-2 explicitly; they go away when the apps are deleted (L83-85).

## 8. Delivery: Concourse

`ci/pipeline.yml` defines the pipeline. It is set with `fly -t wings set-pipeline -p bw-esrefarch-demo -c ci/pipeline.yml -l ci/private.yml` (README, `ci/tips.txt` L10). `ci/private.yml` is **not in the repo** because it holds secrets. Its variable names, from the README example and `((…))` references, are `cf-trading-engine-url`, `cf-trader-app-url`, `cf-trader-ui-url`, `cf-endpoint`, `cf-user`, `cf-password`, `cf-org`, `cf-space`, `skip-ssl`, `webhook`, `git-uri` and `git-private-key`. The README links the team's Concourse at `wings.pivotal.io`, pipeline `bw-esrefarch-demo`.

### Jobs

| ID | Job | Triggers / `passed` | Steps | Source |
|---|---|---|---|---|
| CI-1 | `just-build-it` | manual (`get: manualtrigger`, `trigger: false`) | gate only | `ci/pipeline.yml` L4-7 |
| CI-2 | `build-trading-engine` | `manualtrigger` passed `just-build-it`; `source-code` (trigger) | task `package-trading-engine` (CI-11) → `put: push-to-pcf` with `manifest: source-code/trading-engine/manifest.yml`, `path: package-output/trading-engine.jar` → Slack | `ci/pipeline.yml` L9-33 |
| CI-3 | `build-trader-app` | same as CI-2 | task `package-trader-app` (CI-12) → `put: push-to-pcf` with `manifest: source-code/trader-app/manifest.yml`, `path: package-output/trader-app.jar` → Slack | `ci/pipeline.yml` L35-59 |
| CI-4 | `build-trader-ui` | same as CI-2 | task `package-trader-ui` (CI-13) → `put: push-to-pcf` with `manifest: package-output/manifest.yml` (the manifest's `path: build` resolves inside `package-output`) → Slack | `ci/pipeline.yml` L61-85 |
| CI-5 | `smoke-test-trading-engine` | passed `build-trading-engine` | task CI-14 with `URL: ((cf-trading-engine-url))` → Slack | `ci/pipeline.yml` L87-110 |
| CI-6 | `smoke-test-trader-app` | passed `build-trader-app` | task CI-15 with `URL: ((cf-trader-app-url))` → Slack | `ci/pipeline.yml` L112-135 |
| CI-7 | `e2e-test` | passed `smoke-test-trading-engine`, `smoke-test-trader-app`, `build-trader-ui` | task `integration-test-both-sides` (CI-16) with `engineURL`, `appURL`, `uiURL` → Slack (`<!here>` on failure) | `ci/pipeline.yml` L137-162 |

### Resources and resource types

| ID | Name | Type | Detail | Source |
|---|---|---|---|---|
| CI-8 | `manualtrigger` | `time` | `interval: 1m`. Used as the shared gate from CI-1 | `ci/pipeline.yml` L174-176 |
| CI-9 | `source-code` | `git` | `uri: ((git-uri))`, `branch: master`, `private_key: ((git-private-key))` | `ci/pipeline.yml` L178-183 |
| CI-10 | `push-to-pcf` (TAS deploy target) | `cf` | `api: ((cf-endpoint))`, `username: ((cf-user))`, `password: ((cf-password))`, `organization: ((cf-org))`, `space: ((cf-space))`, `skip_cert_check: false`. A `slack-alert` resource of custom type `slack-notification` (`cfcommunity/slack-notification-resource:latest`, `url: ((webhook))`, `insecure: true`) sends every job's notifications | `ci/pipeline.yml` L164-170, L185-199 |

### Task scripts (`ci/tasks`)

| ID | Task config → script | Image | What it does | TAS coupling |
|---|---|---|---|---|
| CI-11 | `build-trading-engine.yml` → `build-trading-engine.sh` | `maven:3.5-jdk-8-alpine` | `mvn verify` in `trading-engine`. Fails if more than one jar is found, then copies it to `package-output/trading-engine.jar` | output feeds `push-to-pcf` |
| CI-12 | `build-trader-app.yml` → `build-trader-app.sh` | `maven:3.5-jdk-8-alpine` | `mvn verify` in `trader-app` (runs the Spring Cloud Contract tests), copies `trader-app.jar` to `package-output/` | output feeds `push-to-pcf` |
| CI-13 | `build-trader-ui.yml` → `build-trader-ui.sh` | `node` (untagged) | `npm install && npm run build`, copies `manifest.yml` and the `Staticfile` into `package-output/` | ships the staticfile manifest (APP-3) |
| CI-14 | `smoke-test-trading-engine.yml` → `smoke-test-trading-engine.sh` | `ubuntu:latest` | `GET $URL/actuator/health` must return `UP` | targets the TAS route (RTE-4) |
| CI-15 | `smoke-test-trader-app.yml` → `smoke-test-trader-app.sh` | `ubuntu:latest` | health `UP`, and `GET $URL/command/api` returns at least one command | targets the TAS route (RTE-4) |
| CI-16 | `e2e-test-both-sides.yml` → `e2e-test-both-sides.sh` | `ubuntu:latest` | health on both apps; `/actuator/info` on both returns 200; UI returns 200; `POST /actuator/data-initializer` returns `true`; `/command/api` returns 200 (create-company assertions are commented out, L106-131) | targets the TAS routes (RTE-4) |
| CI-17 | `ci/run-tests.sh` (local runner, not a pipeline task) | host | runs CI-14, CI-15 and CI-16 in sequence | `if [ -n $engineURL ]` (unquoted) is always true, so it always overwrites the URLs with the `*.cfapps.io` hosts (L5-21) |
| CI-18 | `ci/tasks/archive/*` (10 files) | `java:8` | Gradle-era `command-side` / `query-side` / `common-api` package and unit-test tasks | **not used** by any job in `ci/pipeline.yml`, and the modules they reference no longer exist. Listed so the mapping can mark them "drop" |

Minor script issues worth carrying into the port: `build-trading-engine.sh` L6 and `build-trader-app.sh` L6 echo an undefined `${OLDPATH}` (they mean `${FOLDER}`). `ci/tips.txt` holds operator notes (local Concourse `pcf-cqrs-demo` pipeline, `wings` target) and references a task that no longer exists (`ci/tasks/build-command-side.yml`).

## 9. cf CLI operator scripts

| ID | Script | cf operations | Notes |
|---|---|---|---|
| OPS-1 | `pave.sh` | `cf login -a https://api.run.pivotal.io`, then 5× `cf create-service` (SVC-1 … SVC-5, free plans) and `watch cf services` | documented path (README §1) |
| OPS-2 | `bigpave-pws.sh` | same as OPS-1 with paid PWS plans | |
| OPS-3 | `bigpave-pcf.sh` | 5× `cf create-service` against the current target (no login). Uses `p.mysql`, `p.rabbitmq` and the `standard` SCS plans | enterprise PCF |
| OPS-4 | `deploy-backend.sh` | login, `mvn clean package -DskipTests=true`, push APP-1 and APP-2 with `--random-route` (RTE-1/RTE-2), add NET-1 and NET-2 | |
| OPS-5 | `deploy-frontend.sh` | login, `npm install && npm run build`, push APP-3 with `--random-route` (RTE-3) | expects RTE-5 to have been edited by hand first (README §3) |
| OPS-6 | `teardown.sh` | `cf stop` ×3, `cf us` ×9 (including the stale UI→`config` unbind), `cf ds` ×5, `cf delete` ×3 | L2 is missing its leading `#`, so bash tries to run `Use` as a command before `set -eu` (prints an error and continues) |

Post-deploy step outside the scripts: `curl -sL -X POST ${trader-app-url}/actuator/data-initializer` seeds companies, users and cash (README §2). CI-16 repeats it.

## 10. Open items for the TAS → GKE mapping (`s1.2`)

The mapping itself is in [`tas-gke-mapping.md`](tas-gke-mapping.md); its §10 resolves each item below as `OPEN-1`…`OPEN-7`, in order.

1. **RTE-6 `axontrader.cfapps.io`**: unconfirmed. Only the `HostURLsMapping` key and the README link text name it, and the README link actually goes to `esrefarch-demo-trader-ui.cfapps.io`. If it was mapped, that happened outside the repo, so its owner, domain and TLS settings are unknown. Confirm with the TAS org owner, then decide whether GKE gets an equivalent host.
2. **`cfapps.io` / PWS is gone.** PWS (`api.run.pivotal.io`, `*.cfapps.io`) was shut down in January 2021. Every hard-coded host in RTE-4, RTE-5, CFG-4, CI-17, `http-api.http` and the OPS scripts points at a dead platform. The live TAS foundation (if any) behind this migration is not recorded in the repo. Confirm its API endpoint, org/space and actual service plans (enterprise `p.mysql`/`p.rabbitmq`, as in OPS-3, is the likely shape).
3. **ESarch-conf (SVC-5 backend)** is a third-party public repo with no pinned label. Decide whether to vendor CFG-2/CFG-3 into this repo (for example as ConfigMaps or `application-gke.yml`) or keep a Config Server.
4. **`ci/private.yml` values** (Concourse credentials, Slack webhook, deploy key) are not in the repo. Their GKE/CI equivalents have to be provisioned as secrets, never committed.
5. **SVC-4 replacement.** Axon's Spring Cloud command bus needs DiscoveryClient metadata, and `fallback-to-http-get=false` today. Choose between running APP-4 (Eureka) in-cluster and Kubernetes discovery with `fallback-to-http-get=true`.
6. **`ddl-auto` precedence** (§5). Without SVC-5 the apps fall back to `create`. The GKE config has to set `update`, or a migration tool, explicitly.
7. **Runtime credential wiring for SVC-1/2/3** is inferred, not confirmed (§3 note). The GKE side needs explicit `spring.datasource.*` and `spring.rabbitmq.*` settings.
