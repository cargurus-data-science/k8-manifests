# k8-manifests

Kubernetes deployment manifests for the CarGurus datasci **`transmission-runtime`**
EKS cluster (account `cargurus-datasci` / `457497801237`, `us-east-1`). Most
workloads ship as **Helm charts**; a couple of out-of-band pieces are Kustomize
targets or raw CRs. The cluster itself, its node groups, IAM roles, Pod Identity
associations, ECR repos, and platform controllers are **Terraform-owned** and
live elsewhere — this repo only describes what runs *on* the cluster.

## Layout

Everything lives under [`applications/`](applications/), one directory per app:

| Path | Kind | What it is |
|---|---|---|
| [`applications/turbo/`](applications/turbo/) | Helm chart | Turbo FastAPI backend + Next.js frontend, as a namespace tenant. Routes via a Terraform-owned internal ALB (`ClusterIP` + `TargetGroupBinding`). |
| [`applications/transmission/`](applications/transmission/) | Helm chart | **One parameterized chart for every Transmission service** (dashboard backend/frontend, mesh, cronjobs, …). Per-service-per-env overrides in [`values/`](applications/transmission/values/). |
| [`applications/risingwave/`](applications/risingwave/) | Kustomize | The `RisingWave` custom resource + supporting objects, applied out-of-band (`kubectl apply -k`) after the operator install. |
| [`applications/observability/`](applications/observability/) | Raw manifest | `OpenTelemetryCollector` CR reconciled by the ADOT operator — OTLP ingest + Prometheus scrape → Amazon Managed Prometheus. Applied out-of-band. |

Each application has its own README with prerequisites, install/deploy order, and
gotchas — **read the per-app README before deploying that app.**

## Conventions across the repo

- **Terraform owns the platform, this repo owns the workloads.** Namespaces, IAM
  roles, Pod Identity associations, ECR repos, and controllers (AWS Load Balancer
  Controller, external-dns, cert-manager, ADOT) come from Terraform. Charts here
  never create them.
- **EKS Pod Identity, not IRSA.** ServiceAccounts carry **no** `role-arn`
  annotation; the IAM role is bound control-plane-side by a Pod Identity
  association keyed on `(namespace, service-account-name)`. Names must match what
  Terraform associated or credentials silently fail to bind.
- **Secrets are created out-of-band** (from AWS Secrets Manager) as plain
  Kubernetes Secrets. Charts reference them by name and never template a Secret
  value into git.
- **Image tags are immutable SHAs**, never `:latest`.
- **GitOps-ready.** Charts and Kustomize targets are authored so `helm template` /
  `kustomize build` alone render the full, correct manifest set (no `lookup()`,
  cluster-state hooks, or nondeterminism) — adopting ArgoCD later means adding an
  `Application` per app/env, no manifest change.

## Deploying

Deploys are Helm-via-CI / `kubectl` — see each app's README for the exact
sequence. Quick shape:

```bash
# Helm charts (turbo, transmission)
helm upgrade --install <release> ./applications/<app> \
  -n <namespace> -f applications/<app>/values-<env>.yaml \
  --set <image>.tag=<sha>

# Kustomize target (risingwave) — after the operator + CRD are established
kubectl apply -k applications/risingwave/

# Raw CR (observability)
kubectl apply -f applications/observability/otel.yaml
```

## Local validation

```bash
# Helm charts
helm lint ./applications/<app> -f applications/<app>/values-<env>.yaml
helm template <release> ./applications/<app> -n <namespace> -f applications/<app>/values-<env>.yaml \
  | kubeconform -ignore-missing-schemas -strict -summary
helm unittest ./applications/<app>            # where a tests/ dir exists (e.g. turbo)

# Kustomize
kustomize build applications/risingwave/ | kubeconform -ignore-missing-schemas -strict -summary
```
