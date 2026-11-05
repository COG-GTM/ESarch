# Deploying Axon Trader to GKE

How a change gets from `master` to production on GKE, how to roll it back, and how to run the same pipeline on a
local `kind` cluster. Replaces the Concourse `push-to-pcf` jobs (see `docs/migration/tas-gke-mapping.md`, section 8).

## Pipeline

```
merge to master
  └─ ci.yml: build, test, Trivy scan, publish  → staging Artifact Registry, <service>:<git sha> + digests
       └─ deploy-staging.yml                    → helm upgrade (values-staging.yaml) + smoke + e2e, rollback on failure
            └─ deploy-prod.yml                  → waits for `production` approval
                 └─ promote job                 → copy the staging digests to the prod registry (no rebuild),
                                                  helm upgrade (values-prod.yaml) + smoke + e2e, rollback on failure
```

| Piece | What it does |
|---|---|
| `.github/workflows/ci.yml` | Builds and scans the four images, pushes them on `master` and emits `{"<service>": "sha256:..."}` |
| `.github/workflows/deploy-staging.yml` | Deploys those digests to staging; on success uploads the `staging-release` artifact (`release.json`: tag + digests, kept 90 days) and returns `result=deployed` |
| `.github/workflows/deploy-prod.yml` | `release` job shows the release (tag + digests) in its summary; `promote` job runs in the `production` environment |
| `ci/deploy/promote-images.sh` | `skopeo copy --all --preserve-digests` (pinned skopeo 1.16 image) of each `<staging registry>/<service>@<digest>` to `<prod registry>/<service>:<sha>`, then checks the prod registry serves the same digest |
| `ci/deploy/helm-deploy.sh` | `helm upgrade --install` pinned by digest, `kubectl rollout status`, `ci/deploy/smoke.sh` (newman `ESArchSmokeTest.postman_collection.json` + `ci/tasks/e2e-test-both-sides.sh` + the public `/api/command/api` route); any failure runs `helm rollback` to the revision deployed before |

Production never builds anything: the image bytes that run in prod are the ones staging tested, addressed by digest.
`trading-engine` stays at one replica in every environment (decision d-engine-replicas); only `trader-app` and
`trader-ui` autoscale in prod.

## One-time setup

### `production` environment (repository admin)

Settings → Environments → New environment `production`:

- **Required reviewers**: the release approvers (at least one person other than the usual committer).
- **Deployment branches and tags**: selected branches, `master` only.
- Optionally **Prevent self-review**.

Or with the API (needs admin on the repository; reviewer ids from `gh api users/<login> --jq .id` or `gh api orgs/COG-GTM/teams/<team> --jq .id`):

```bash
gh api -X PUT repos/COG-GTM/ESarch/environments/production --input - <<'JSON'
{
  "prevent_self_review": true,
  "reviewers": [{"type": "Team", "id": 1234567}],
  "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}
}
JSON
gh api -X POST repos/COG-GTM/ESarch/environments/production/deployment-branch-policies -f name=master -f type=branch
```

### Workload Identity Federation (Terraform)

`infra/terraform/envs/prod` creates the prod WIF pool for this repository with `ci_allowed_refs = ["refs/heads/master"]`
and `ci_allowed_environments = ["production"]`: Google only exchanges GitHub tokens minted for a `master` job of the
`production` environment, so a prod token cannot exist without the reviewers' approval. No service account key is
ever created or stored.

### Repository variables

Values are Terraform outputs of `infra/terraform/envs/prod` (none of them is a secret). Until the four `PROD_GCP_*` /
`PROD_GKE_CLUSTER` variables are set, `deploy-prod.yml` is skipped with a notice and nothing waits for approval.

| Variable | Terraform output / value |
|---|---|
| `PROD_GCP_WORKLOAD_IDENTITY_PROVIDER` | `ci_workload_identity_provider` |
| `PROD_GCP_CI_SERVICE_ACCOUNT` | `ci_service_account` (`roles/container.developer`, Artifact Registry writer on the prod repository) |
| `PROD_GCP_ARTIFACT_REGISTRY` | `artifact_registry_url` |
| `PROD_GKE_CLUSTER` | `projects/<project>/locations/<gke_cluster_location>/clusters/<gke_cluster_name>` |
| `PROD_CLOUDSQL_INSTANCE_CONNECTION_NAME` | `cloudsql_instance_connection_name` |
| `PROD_CLOUDSQL_PSA_CIDR` | private services access range of the Cloud SQL instance |
| `PROD_URL` | `https://<prod host>` served by the platform Gateway |

The promote job also reads the staging images with the staging `GCP_WORKLOAD_IDENTITY_PROVIDER`,
`GCP_CI_SERVICE_ACCOUNT` and `GCP_ARTIFACT_REGISTRY` (README, GitHub Actions section). `SLACK_WEBHOOK_URL` (optional
secret) gets the result of both deploys.

## Releasing

1. Merge to `master`. `ci.yml` publishes, `deploy-staging` deploys and tests staging.
2. When staging passes, the `Promote to production (approval)` job of the same run waits. Open the run: the
   `Staging-verified release` summary lists the git SHA and the four digests that will go to production.
3. A required reviewer clicks **Review deployments → production → Approve**. Only the latest waiting release stays
   pending (the `deploy-prod` concurrency group replaces older waiting ones), and the approval expires after 30 days.
4. The promote job copies the digests, deploys with `values-prod.yaml`, runs the smoke + e2e against prod and posts to
   Slack. Its summary shows the helm result; logs are in the `prod-smoke` artifact.

To promote an earlier release (the latest pending one was replaced, or to roll forward/back to a known release):
Actions → `deploy-prod` → **Run workflow** on `master` with `staging-run-id` = the id of the `ci` (or `deploy-staging`)
run on `master` whose staging deploy passed. It promotes that run's `staging-release` artifact, behind the same approval.

Note: the smoke collection writes test data (`/actuator/data-initializer`, orders) into the prod databases, as the
Concourse smoke did. Run the first promotion before cutover traffic (s6.3).

## Rolling back

### Automatic

Any failure after `helm upgrade` starts (a rollout that does not complete within `ROLLOUT_TIMEOUT`, the newman smoke,
the e2e, the public route) runs `helm rollback axon-trader <previous revision> --wait` and fails the job. The job
summary and Slack say which: `rolled-back-to-<n>`, `rollback-failed` (look now), `no-rollback` (first install) or
`not-deployed` (failed before touching the cluster, prod unchanged).

### Manual: `helm rollback`

From a shell with access to the prod cluster (`gcloud container clusters get-credentials`, `roles/container.developer`):

```bash
helm -n axon-trader history axon-trader
# the revision to go back to (the last superseded one is the release before the current)
previous=$(helm -n axon-trader history axon-trader -o json | jq -r '[.[] | select(.status == "superseded")] | last | .revision')
# the digests it ran
helm -n axon-trader get values axon-trader --revision "$previous" -o json |
  jq '{"trading-engine", "trader-app", "discovery-server", "trader-ui"} | map_values(.image.digest)'
helm -n axon-trader rollback axon-trader "$previous" --wait --timeout 600s
for d in discovery-server trading-engine trader-app trader-ui; do kubectl -n axon-trader rollout status deploy/$d; done
NS=axon-trader PUBLIC_URL=https://<prod host> bash ci/deploy/smoke.sh
```

### Manual: redeploy the previous digests through the pipeline

Preferred when there is time, because it is approved, audited and smoke-tested like any release: run `deploy-prod`
by hand with the `staging-run-id` of the release to go back to (see Releasing). The digests that release ran are in
its `staging-release` artifact, in the `Staging-verified release` summary of its run and in `helm get values` above.

Database changes are not rolled back by either path: Flyway migrations must stay backward compatible with the
previous release.

## Local `kind` workflow

The same scripts run against a local `kind` cluster with MySQL/RabbitMQ stand-ins (`ci/kind/`), with no GCP or TAS
access. Needs docker, kind, kubectl, helm, jq, node (`npx newman`), and uuidgen (the promotion proof runs skopeo from a pinned container image).

```bash
# build the four images as CI does
./mvnw -B -DskipTests package jib:dockerBuild
docker build -t esarch/trader-ui:latest trader-app-ui

deploy/helm/scripts/validate.sh                 # helm lint + kubeconform for every values file
bash ci/kind/verify-helm-smoke.sh               # install the chart, smoke + e2e
bash ci/kind/verify-deploy-rollback.sh          # staging deploy logic: good deploy, two broken images rolled back
bash ci/kind/verify-prod-promotion.sh           # prod promotion: staging digests -> prod registry -> values-prod.yaml,
                                                # automatic rollback of a broken release, manual helm rollback
```

`verify-prod-promotion.sh` runs two local registries standing in for the staging and prod Artifact Registries; the
cluster can only pull from the prod one, and the script checks every Deployment and pod runs
`<prod registry>/<service>@<staging digest>`. `ESARCH_KIND_KEEP=1` keeps the cluster (`kind-esarch-prod`) and
registries for poking around; `kind delete cluster --name esarch-prod && docker rm -f esarch-staging-registry esarch-prod-registry` cleans up.

## Not proved yet

No GCP project exists yet: the staging deploy and the dry-run promotion to the real prod cluster (before cutover
traffic) are still owed once the Terraform is applied and the variables above are set.
