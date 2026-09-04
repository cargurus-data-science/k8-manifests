# Turbo Helm chart (backend + frontend)

Packages the Turbo FastAPI backend (`turbo-app`) and Next.js frontend
(`turbo-frontend`) as a namespace tenant on the shared `transmission-runtime`
EKS cluster (account `cargurus-datasci-dev` / 457497801237, us-east-1).

Routing stays on the **Terraform-owned internal ALB** — this chart creates
`ClusterIP` Services and `TargetGroupBinding` CRs (`targetType: ip`), never an
Ingress. Secrets are plain Kubernetes Secrets created **out-of-band**; the chart
references them by name and never templates a Secret value.

## Prerequisites (out-of-band — do these BEFORE `helm upgrade`)

1. **Namespace exists and is readiness-gate-labeled** (Terraform-owned):
   ```bash
   kubectl get ns turbo --show-labels   # expect elbv2.k8s.aws/pod-readiness-gate-inject=enabled
   ```
   The chart does not create or label the namespace.

2. **Three Secrets exist in the namespace**, populated from the AWS Secrets
   Manager bundles (analogous to `scrt_apply.py`). Without them the backend
   pod fails `CreateContainerConfigError`:
   | Secret | Source bundle |
   |---|---|
   | `turbo-core` | `turbo/core` (same name in both envs — distinct AWS accounts) |
   | `turbo-external-tools` | `turbo/external-tools` |
   | `turbo-arango` | `turbo/arango` |
   ```bash
   kubectl -n turbo get secret turbo-core turbo-external-tools turbo-arango
   ```

3. **Pod Identity associations exist** (Terraform) for ServiceAccounts
   `turbo` (S3 media + Bedrock) and `turbo-frontend` (no AWS access).

## Install / upgrade

Fill the `REPLACE_ME_*` markers in `values.yaml` / `values-<env>.yaml` from
Terraform outputs (ECR repos, target-group ARNs, media bucket, Redis URL) and
the image SHA from the build, then:

```bash
# production
helm upgrade --install turbo ./applications/turbo -n turbo     -f applications/turbo/values-prod.yaml \
  --set backend.image.tag=<sha> --set frontend.image.tag=<sha>

# development
helm upgrade --install turbo ./applications/turbo -n turbo-dev -f applications/turbo/values-dev.yaml \
  --set backend.image.tag=<sha> --set frontend.image.tag=<sha>
```

The namespace comes from `-n`, not the chart. Image tags are immutable SHAs —
never `:latest`.

## Install ordering (frontend vs backend)

There is **no required ordering** and the chart enforces none. The frontend
depends on the backend only at request time (`server-api.ts` reads
`BACKEND_URL` per request), so it boots cleanly with the backend down and
recovers once the backend is ready — no crash loop. The backend's only
ordering constraints are internal (Secrets + Pod Identity present, DB
migrations run). Apply the whole chart in one release; Kubernetes converges.
For a manual first bootstrap, backend-first is natural but optional.

## Secret availability & ordering

A pod that references a missing Secret does **not** hard-fail — it sits in
`CreateContainerConfigError` and the kubelet **retries automatically**, so the
app converges once the Secret appears. That native retry is the backstop under
both the current model and a future ESO one; the chart itself enforces no
secret ordering.

**Today (out-of-band Secrets).** The three Secrets in Prerequisites must exist
*before* `helm upgrade`. If you install first, the backend simply loops in
`CreateContainerConfigError` until you apply them — no data risk, just a stalled
rollout.

**Future (External Secrets Operator).** The chart already carries `SecretStore`
+ `ExternalSecret` CRs (`templates/externalsecrets.yaml`) behind
`.Values.externalSecrets.enabled` (default off); flipping it on makes ESO the
source of the three Secrets instead of out-of-band creation. The ESO *operator*
stays a cluster-wide platform addon — never in this chart. ESO reconciles
**asynchronously**, so Helm apply-order alone can't guarantee the Secret exists
when pods start, and Helm's default kind-sort actually applies `ExternalSecret`
*after* `Deployment`. Two ways to order it:

- **Default — native retry.** Apply everything together; pods self-heal within
  seconds once ESO syncs. Simplest, and the operator is already running
  cluster-wide. Recommended unless a real problem appears.
- **Hard gate (only if needed).** `helm.sh/hook: pre-install,pre-upgrade` +
  `hook-weight` on the `SecretStore` (`-10`) and `ExternalSecret` (`-5`), plus a
  weight-`0` wait Job running `kubectl wait --for=condition=Ready
  externalsecret/<name>`. Helm blocks on Job hooks, so the Deployment isn't
  applied until the Secrets are `Ready`. Costs: RBAC for the Job's
  ServiceAccount, and hook resources are awkward in `helm diff` / `get manifest`.

Ordering only covers **first install** (Secret absent). It does nothing for
**value rotation** on a running deployment — the pod is already up with stale
env. That needs Stakater Reloader (restart pods when Secret content changes) and
is tracked separately.

## Backend is pinned to one replica

`backend.replicas` is `1` and must stay `1`: the app runs in-process asyncio
pollers (scheduled sync, workflow cron, delivery/recovery sweeps) that a second
pod would duplicate. No HPA until leader election exists.

## Future: ArgoCD source

This chart is authored to be a clean ArgoCD source — `helm template` alone
renders the full, correct manifest set (no `lookup()`, no cluster-state hooks,
no `Date`/random, no dynamic `--set` beyond image SHA). Adopting ArgoCD later
means adding an `Application` per environment (or an `ApplicationSet` over the
two value files) that points at this path — **no chart change**. The
namespace stays externally managed (no `CreateNamespace`), and the out-of-band
Secrets are invisible to Argo prune by design. Visible install sequencing, if
ever wanted, is a `argocd.argoproj.io/sync-wave` annotation added at that time.

## Local validation

```bash
helm lint ./applications/turbo -f applications/turbo/values-prod.yaml
helm lint ./applications/turbo -f applications/turbo/values-dev.yaml
helm template turbo ./applications/turbo -n turbo -f applications/turbo/values-prod.yaml <…--set images/arns…> \
  | kubeconform -ignore-missing-schemas -strict -summary
```
