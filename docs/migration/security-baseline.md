# GKE security baseline (s5.4)

Checked on kind with `ci/kind/verify-security-baseline.sh` (the merged chart `deploy/helm/axon-trader` with
`ci/kind/values-kind*.yaml`, namespace labelled `pod-security.kubernetes.io/enforce=restricted`) plus a static review of
the chart rendered with `values-staging.yaml` / `values-prod.yaml` and of `infra/k8s`. There is no GCP staging cluster
yet: **the live re-check on GKE staging is still owed** (same script sections 1-4 against the real namespace, plus the
items marked "GKE re-check" below).

## Findings

| # | Item | Before | Status |
| --- | --- | --- | --- |
| F1 | Pod Security Standard | `infra/k8s/platform/namespace.yaml` enforced `baseline` (warn/audit `restricted`) | **Fixed**: `enforce: restricted` (pinned `v1.33`). RabbitMQ operator pods get a restricted `override` (seccomp, no privilege escalation, `drop: [ALL]`, uid 999); the prod patch no longer replaces `containers`. Chart, smoke and check Jobs were already compliant. |
| F2 | Restricted PSS on kind | kind namespace had no PSS label; MySQL/RabbitMQ stand-ins and the NetworkPolicy probe pods ran as root | **Fixed**: `ci/kind/setup.sh` labels the namespace `enforce=restricted` for every kind check; stand-ins run as uid 999 with seccomp/`drop: [ALL]`; probe pods (`kind_probe`) use a restricted securityContext. |
| F3 | NetworkPolicies | Ingress default-deny plus per-app allow-lists (s3.5) | **OK** (no change): every ingress path outside the s3.5 flows is a blocked curl (unlabelled, trader-ui, discovery-server and trader-app -> trader-ui pods); the s3.5 flows connect. |
| F4 | Egress deny | Chart egress policies allow only s3.5 flows, DNS and (GKE) metadata/Google APIs; `trader-ui` none | **GKE re-check owed**: policies render correctly, but kind's CNI (kindnet / kube-network-policies) did not enforce egress on this host: chart pods reached a policy-free in-cluster target and `1.1.1.1:80`. The script reports these as INFO; the deny must be shown on GKE Dataplane V2 before acceptance. |
| F5 | Credentials | Secrets from ExternalSecrets (Secret Manager) via Workload Identity KSAs; kind generates throwaway Secrets | **OK** (no change): generated secret values appear in no Helm value, rendered manifest, ConfigMap or pod spec; credential env vars come only from `secretKeyRef`/`envFrom`; image config and Trivy secret scan clean. |
| F6 | Env dumps | `management.endpoints.web.exposure.include=*` in the base `application.properties` of trader-app and trading-engine (the `kubernetes` profile already narrowed it) | **Fixed**: base exposure is `health,info,prometheus` (+ `data-initializer` on trader-app), so `/actuator/env`, `configprops`, `heapdump`, `beans` etc. are gone on every profile (TAS, local, GKE). |
| F7 | Actuator public exposure | HTTPRoute routes only `/`, `/api/command/*`, `/api/query/*` | **OK** (no change): nothing under `/actuator` or `/api/actuator` (incl. `..` / `%2f` traversal) reaches an actuator through the Gateway. |
| F8 | In-cluster `info` and `data-initializer` | Not public, reachable only from NetworkPolicy peers | **Accept**: needed by the smoke/e2e scripts (`/actuator/info`, `POST /actuator/data-initializer`); `data-initializer` seeds demo data, keep or drop is a human decision. |
| F9 | HTTPS-only | Platform Gateway: HTTPS listener + HTTP listener that only 301s; chart-owned Gateway (`gateway.create: true`) served the app on its HTTP listener; no HSTS; LB default SSL policy (COMPATIBLE, TLS 1.0+) | **Fixed**: Terraform `google_compute_ssl_policy` (MODERN, TLS 1.2+) attached with a `GCPGatewayPolicy`; chart-owned Gateway gets an HTTP->HTTPS 301 route; `route.hsts` adds `Strict-Transport-Security` on routed responses. kind keeps an HTTP-only stand-in (`hsts: ""`). GKE re-check: `curl -I http://<host>` -> 301, `openssl s_client -tls1_1` refused. |
| F10 | Trivy CVEs | CI gate with `ci/trivy/critical-baseline.yaml` | **Accept (d-runtime)**: 48 distinct critical CVEs on the three JVM images (Boot 2.0.3 / Spring 5.0.7 / Java 8 libraries), all already in the baseline (expires 2027-05-01), no new ones; trader-ui (alpine 3.24) has none critical/high. List below. |

## Critical CVEs kept with the Boot 2.0 / Java 8 runtime

Trivy 0.76.0, `--severity CRITICAL`, images built from this branch (trading-engine 42, trader-app 47, discovery-server
37 distinct; 48 overall). No OS-package criticals (eclipse-temurin 8 on ubuntu 24.04). Clearing them needs the runtime
upgrade the d-runtime decision deferred.

| Library | CVEs | IDs |
| --- | --- | --- |
| `dom4j 1.6.1` | 1 | CVE-2020-10683 |
| `freemarker 2.3.28` | 1 | CVE-2026-84939 |
| `h2 1.4.197` | 2 | CVE-2021-42392, CVE-2022-23221 |
| `jackson-databind 2.8.11` | 20 | CVE-2018-11307, CVE-2018-14718, CVE-2018-14719, CVE-2018-14720, CVE-2018-14721, CVE-2018-19360, CVE-2018-19361, CVE-2018-19362, CVE-2018-7489, CVE-2019-14379, CVE-2019-14540, CVE-2019-16335, CVE-2019-16942, CVE-2019-16943, CVE-2019-17267, CVE-2019-17531, CVE-2019-20330, CVE-2020-8840, CVE-2020-9547, CVE-2020-9548 |
| `jackson-databind 2.9.6` | 19 | CVE-2018-14718, CVE-2018-14719, CVE-2018-14720, CVE-2018-14721, CVE-2018-19360, CVE-2018-19361, CVE-2018-19362, CVE-2019-14379, CVE-2019-14540, CVE-2019-16335, CVE-2019-16942, CVE-2019-16943, CVE-2019-17267, CVE-2019-17531, CVE-2019-20330, CVE-2020-8840, CVE-2020-9546, CVE-2020-9547, CVE-2020-9548 |
| `jetty-server 9.2.24.v20180105` | 2 | CVE-2017-7657, CVE-2017-7658 |
| `netty-codec-http 4.1.25.Final` | 1 | CVE-2019-20444 |
| `netty-handler 4.1.25.Final` | 1 | CVE-2026-75595 |
| `spring-beans 5.0.7.RELEASE` | 1 | CVE-2022-22965 |
| `spring-boot-actuator-autoconfigure 2.0.3.RELEASE` | 1 | CVE-2023-20873 |
| `spring-boot-starter-web 2.0.3.RELEASE` | 1 | CVE-2022-22965 |
| `spring-boot-starter-webflux 2.0.3.RELEASE` | 1 | CVE-2022-22965 |
| `spring-security-core 5.0.6.RELEASE` | 1 | CVE-2022-22978 |
| `spring-security-web 5.0.6.RELEASE` | 3 | CVE-2022-22978, CVE-2024-38821, CVE-2026-22732 |
| `spring-web 5.0.7.RELEASE` | 1 | CVE-2016-1000027 |
| `spring-webflux 5.0.7.RELEASE` | 1 | CVE-2022-22965 |
| `spring-webmvc 5.0.7.RELEASE` | 2 | CVE-2022-22965, CVE-2026-47884 |
| `tomcat-embed-core 8.5.31` | 10 | CVE-2018-8014, CVE-2020-1938, CVE-2025-24813, CVE-2026-41293, CVE-2026-43512, CVE-2026-43515, CVE-2026-55276, CVE-2026-65182, CVE-2026-65905, CVE-2026-68525 |
| `xstream 1.4.10` | 2 | CVE-2013-7285, CVE-2019-10173 |
