# Reusable Devin Playbook: Migrate a TAS/CF application to GKE [v1]

This is the templatized version of the work in this repository. It is written to be run per
application across an estate: the assessment step is the same every time, and the per-app variation
shows up in exactly two places — the platform-injected configuration, and any discovery/messaging
coupling.

Run the phases as separate sessions and separate PRs. Do not collapse them: a single PR that changes
the packaging, the platform, and the framework at once makes any failure impossible to attribute.

---

## Phase 0 — Assessment (no code changes)

**Prompt**

> Inventory this Cloud Foundry / Tanzu Application Service application and produce a TAS→GKE migration
> assessment at `demo-kit/01-migration-assessment.md`. Every claim must cite a file in the repo.
> Cover: each `cf push` unit and its manifest (buildpack, health-check-type, timeout, instances,
> bound services); every bound marketplace service and which code consumes it; and every piece of
> platform behaviour the app depends on — `VCAP_SERVICES` credential injection, the buildpack-activated
> Spring profile, CF actuator integration, routes, `cf add-network-policy` calls, health-check type,
> and the CI system. Then map each item to its GKE target. Call out separately: (a) any architectural
> decision the migration forces, (b) anything YAML cannot solve — data migration, scaling bounded by
> application design, out-of-support runtimes. Do not change application code in this phase.

**Done when** the assessment exists, every mapping row cites a file, and the known-gaps section names
the things that are *not* being solved.

## Phase 1 — Containerize

**Prompt**

> Replace the buildpacks with container images, keeping the runtime contract identical — do not upgrade
> the framework, language level, or dependencies, and do not change application source unless it is
> unavoidable (if it is, stop and explain what and why).
> For each JVM app: a multi-stage Dockerfile matching the language level the project declares, a JRE
> runtime stage, a non-root user, container-aware heap sizing (the CF memory calculator's job), and the
> same artifact name the CF manifest used. For static frontends: build the bundle and serve it from
> nginx, reproducing any `Staticfile` directives (`pushstate: enabled` → SPA history fallback).
> Everything `VCAP_SERVICES` used to inject becomes explicit environment configuration; set
> `management.cloudfoundry.enabled=false`. Read the frontend's API base URL resolution before changing
> it — a same-origin reverse proxy often means zero frontend source changes.
> Add a local compose stack for the backing services so the whole thing runs on one machine.
> Verify: every image builds; the stack comes up; each backend serves `/actuator/health`; the frontend
> loads and its API calls succeed.

## Phase 2 — Kubernetes / Helm

**Prompt**

> Author a Helm chart deploying every workload from the assessment. Map, one resource per assessment
> row: manifest `instances` → replicas (+ HPA only where the application can actually scale out);
> `health-check-type: port` → readiness/liveness on the application health endpoint; manifest `timeout`
> → an equivalent `startupProbe` budget; Config Server content → ConfigMap; `VCAP_SERVICES` credentials
> → Secrets; CF route → Ingress; each `cf add-network-policy` call → a NetworkPolicy. Values must switch
> between in-cluster backing services (for local validation) and managed cloud services (Cloud SQL via
> the Auth Proxy sidecar with Workload Identity) without template changes. Include a chart README
> mapping each resource back to the TAS construct it replaces.
> Verify on a local `kind` cluster: all pods Ready, then exercise a real end-to-end user flow through
> the Ingress. Pods-ready is not the acceptance criterion.

## Phase 3 — Delivery

**Prompt**

> Replace the CF deployment pipeline. Each `cf push` step becomes: build image → push to Artifact
> Registry → `helm upgrade`. Produce both a Cloud Build config and a GitHub Actions workflow, keeping
> the existing pipeline's stage boundaries so the diff is reviewable against it. Verify the build steps
> run and the chart renders.

## Phase 4 (optional) — Remove the platform-shaped components

**Prompt**

> Remove the self-hosted service registry in favour of Kubernetes-native discovery
> (`spring-cloud-kubernetes`: Services + cluster DNS). This changes how commands/requests are routed
> between services, so it is its own PR with its own evidence: show the routing works under the new
> discovery mechanism, not just that the app starts.

---

## Required verification step for every phase that changes code

Before opening the PR:

1. Start the backend and the frontend dev server (or the containerized stack).
2. Open the frontend in a browser and navigate the main pages.
3. Exercise the application's primary write path end to end — for Axon Trader, place a buy or sell and
   confirm the resulting projection appears.
4. **Record a screen recording of that interaction** and attach it to the PR as proof the change had no
   negative impact.

## PR conventions

- Commit messages include `feature` or `bug`.
- Every PR description ends with, on its own line: `Devin-Org: engineering`
- One phase per PR. Each PR states what was verified and what was explicitly left out of scope.
