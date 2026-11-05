# GCP foundation (Terraform)

Foundation for running Axon Trader on GKE: project APIs, network, Artifact Registry, Secret Manager,
service accounts and Workload Identity Federation for CI. The GKE cluster, Cloud SQL and RabbitMQ
build on these outputs in later steps.

```
infra/terraform/
  bootstrap/                      one-time root: versioned GCS bucket for remote state (local state)
  envs/staging, envs/prod         per-environment roots (GCS backend, prefix esarch/<env>)
  modules/
    foundation/                   composes the modules below; least-privilege grants are defined here
    project-services/             google_project_service for the required APIs
    network/                      VPC, private subnet + pods/services secondary ranges, Cloud NAT,
                                  internal firewall, private services access (Cloud SQL private IP)
    artifact-registry/            Docker repository, cleanup policies, repo-scoped reader/writer IAM
    managed-secrets/              Secret Manager secrets (no values) + per-secret accessor IAM
    service-accounts/             service accounts, project roles, optional GKE KSA -> GSA bindings
    workload-identity-federation/ GitHub Actions OIDC pool/provider + CI service account impersonation
  scripts/validate.sh             fmt, validate, mocked tests, tflint (what CI runs)
```

## What gets created per environment

| Resource | Name | Notes |
| --- | --- | --- |
| VPC / subnet | `esarch-<env>` / `esarch-<env>-gke` | private Google access, flow logs, ranges `pods` and `services` |
| Cloud NAT | `esarch-<env>-nat` | egress for private nodes, errors logged |
| Artifact Registry | `<region>-docker.pkg.dev/<project>/esarch-<env>` | prod: immutable tags, cleanup enforced |
| Secrets | `trader-app-db-password`, `trading-engine-db-password`, `rabbitmq-password` | values added out of band |
| WIF | pool `var.wif_pool_id`, provider `github-actions` | only tokens from `var.github_repository` (and `var.ci_allowed_refs`) |

## Service accounts and grants

| Account | Project roles | Resource-scoped grants |
| --- | --- | --- |
| `<env>-gke-nodes` | `roles/container.defaultNodeServiceAccount` | `artifactregistry.reader` on the env repo |
| `<env>-trader-app` | `roles/cloudsql.client` | `secretAccessor` on its DB password and `rabbitmq-password` |
| `<env>-trading-engine` | `roles/cloudsql.client` | `secretAccessor` on its DB password and `rabbitmq-password` |
| `<env>-ci-deployer` | `roles/container.developer` | `artifactregistry.writer` on the env repo; `workloadIdentityUser` for the repo principal set |

The workload accounts are bound to the `axon-trader/trader-app` and `axon-trader/trading-engine`
Kubernetes service accounts when `enable_gke_workload_identity_bindings = true`. Leave it `false`
until the GKE cluster exists: the `<project>.svc.id.goog` pool is created with the first Workload
Identity enabled cluster.

## Usage

No project ids, bucket names or credentials are committed. Copy the examples and fill them in
(both copies are git-ignored):

```bash
# once, with an account that can create buckets in the state project
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars && terraform init && terraform apply

cd ../envs/staging
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl   # bucket = <state bucket from bootstrap>
terraform init -backend-config=backend.hcl
terraform plan -out=staging.tfplan
```

After apply, add secret values without Terraform, e.g.
`printf '%s' "$PASSWORD" | gcloud secrets versions add rabbitmq-password --data-file=- --project=<project>`.

The CI pipeline uses `google-github-actions/auth` with the `ci_workload_identity_provider` and
`ci_service_account` outputs. Workload identity pools are soft-deleted for 30 days, so use a new
`wif_pool_id` after a destroy.

## Validation

`scripts/validate.sh` needs only `terraform` (>= 1.7) and `tflint`, no GCP access. It runs
`terraform fmt -check`, `terraform validate` on every root and module, `terraform test` on
`modules/foundation` with a mocked google provider, and `tflint --recursive` with the terraform and
google rulesets. `.github/workflows/terraform.yml` runs it on every change under `infra/terraform/`.
