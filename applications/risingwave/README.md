# manifests/risingwave/

The RisingWave cluster, applied **out-of-band** (with `kubectl`), not by
Terraform. Terraform owns the cluster, the `risingwave` node group, the app IAM
role + Pod Identity association, and the RDS meta store; these files own the
`RisingWave` custom resource the operator reconciles and its supporting objects.

## What's here

| File | Object |
|---|---|
| `namespace.yaml` | `risingwave` namespace |
| `serviceaccount.yaml` | `risingwave-s3` SA (Pod Identity binds AWS creds to it — no annotation) |
| `configmap.yaml` | `risingwave-config` — forces the aws-sdk-rust S3 client (Pod Identity) |
| `risingwave.yaml` | the `RisingWave` CR — RDS meta store, Hummock S3, internal NLB frontend |
| `kustomization.yaml` | applies the four above in dependency order (`kubectl apply -k`) |

The `postgresql-credentials` Secret is **not** in this directory — it holds the
RDS master password and is created by hand from Secrets Manager (step 3). It must
never live in git.

## Prerequisites

1. `terraform apply` has run in `envs/dev`: the `risingwave` node group (tainted
   `workload=risingwave`), the RW app IAM role + Pod Identity association for
   `(risingwave, risingwave-s3)`, the RDS meta store + its RDS-managed master
   secret in Secrets Manager, and the platform controllers (AWS Load Balancer
   Controller, external-dns, cert-manager) are all up.
2. `kubectl` context points at `transmission-runtime-dev` — the API endpoint is
   private, so you must be on the corporate VPN.
3. `helm` installed locally.

## Deploy sequence

### 1. Install the RisingWave operator (release manifest — provides the CRD)

Per the [official docs](https://docs.risingwave.com/deploy/risingwave-kubernetes),
the operator is a single release manifest applied with **server-side** apply —
not a Helm chart. Server-side is required: the bundled CRDs are too large to fit
in the client-side `last-applied` annotation. The manifest creates its own
`risingwave-operator-system` namespace, so there's no namespace flag.

```bash
# Pin a released version for reproducibility (check the releases page for the
# current tag): https://github.com/risingwavelabs/risingwave-operator/releases
VERSION=v1.3.0
kubectl apply --server-side -f \
  https://github.com/risingwavelabs/risingwave-operator/releases/download/${VERSION}/risingwave-operator.yaml

# — or, unpinned, always the latest release:
# kubectl apply --server-side -f \
#   https://github.com/risingwavelabs/risingwave-operator/releases/latest/download/risingwave-operator.yaml
```

The operator lands on the runtime pool (it carries no `workload=risingwave`
toleration) — correct; only the RW component pods get pinned to the RW node
group. **cert-manager is a hard prerequisite** — it backs the operator's
admission webhooks, and the apply fails with a webhook error if cert-manager
isn't fully initialized yet (wait ~1 min and re-apply). It's installed by the
`eks` module, so it's already up by the time you reach this step.

### 2. Wait for the CRD to be Established

This is the one real ordering gate — the CR can't be accepted until its CRD
exists (`kubectl` / Kustomize apply do not wait on their own):

```bash
kubectl wait --for=condition=Established \
  crd/risingwaves.risingwave.risingwavelabs.com --timeout=120s
```

### 3. Create the meta-store credentials secret (manual, one-time)

The `RisingWave` CR references a `postgresql-credentials` secret with keys
`POSTGRES_USER` / `POSTGRES_PASSWORD`. Re-key the RDS-managed master secret
(JSON `{"username","password"}`) into it. Run with your **datasci-dev** profile,
over the VPN. The namespace must exist first:

```bash
kubectl apply -f manifests/risingwave/namespace.yaml

SECRET_ARN=$(terraform -chdir=envs/dev output -raw rds_meta_secret_arn)
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" --query SecretString --output text)
PG_USER=$(echo "$SECRET_JSON" | jq -r .username)
PG_PASS=$(echo "$SECRET_JSON" | jq -r .password)

# Idempotent (plain `kubectl create secret` errors if it already exists):
kubectl create secret generic postgresql-credentials \
  --namespace risingwave \
  --from-literal=POSTGRES_USER="$PG_USER" \
  --from-literal=POSTGRES_PASSWORD="$PG_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Note: this secret is a *copy*. If the RDS master password is rotated, re-run this
block — the two are not linked (fixed later by External Secrets Operator).

### 4. Apply the manifests

```bash
kubectl apply -k manifests/risingwave/
```

Kustomize applies namespace → serviceaccount → configmap → CR in dependency
order. Re-running is safe (idempotent); if anything raced, re-apply. Editing
`additionalFrontendServiceMetadata` recreates the frontend Service, replacing the
NLB (new hostname, new managed SG id) with ~1 min of downtime.


The CR's `metaStore.postgresql.host` is the dev RDS **address** (host only, no
port). If the RDS instance is ever recreated, refresh it — the address changes:

```bash
terraform -chdir=envs/dev output -raw rds_meta_endpoint   # host:port; drop the :port
```

### 5. Harden the frontend password (required — the NLB is network-reachable)

The frontend is exposed on an internal NLB, so the default empty-password `root`
login must not remain. Port-forward the frontend Service (reliable before DNS
propagates) and set a password. The operator's frontend SQL port is **4567**
(not the standalone/playground default of 4566):

```bash
kubectl -n risingwave port-forward svc/risingwave-frontend 4567:4567 &
psql -h 127.0.0.1 -p 4567 -d dev -U root
# in psql:
ALTER USER root PASSWORD '<a-strong-password>';
```

## Validate

```bash
# operator up
kubectl -n risingwave-operator-system get deploy

# CR reconciled and Running
kubectl -n risingwave get risingwave risingwave

# component pods landed on the RW node group (workload=risingwave)
kubectl -n risingwave get pods -o wide
kubectl get nodes -l workload=risingwave

# internal NLB provisioned + external-dns record
kubectl -n risingwave get svc risingwave-frontend      # EXTERNAL-IP = NLB hostname
nslookup risingwave.datasci.d-gurus.com                 # resolves inside the VPN

# connect over the NLB (post password-hardening) — SQL port is 4567
psql -h risingwave.datasci.d-gurus.com -p 4567 -d dev -U root
```

## Access

Everything below needs the corporate VPN — the NLB has only private IPs and the
API endpoint (used by `port-forward`) is private-only.

### Connect with `psql`

Over the internal NLB (SQL port **4567**; use the `root` password set in step 5):

```bash
psql -h risingwave.datasci.d-gurus.com -p 4567 -d dev -U root
# non-interactive (e.g. scripts / CI):
PGPASSWORD='<root-password>' \
  psql -h risingwave.datasci.d-gurus.com -p 4567 -d dev -U root -c 'select version();'
```

Or via `port-forward` — no NLB/DNS in the path, so it's the reliable fallback
before the external-dns record propagates or if the NLB is mid-reconcile:

```bash
kubectl -n risingwave port-forward svc/risingwave-frontend 4567:4567 &
psql -h 127.0.0.1 -p 4567 -d dev -U root
```

### Open the meta dashboard

The dashboard is served by the **meta** node (port `5691`) and is deliberately
not fronted by the NLB (the operator only exposes the frontend Service as a
LoadBalancer). Reach it with a `port-forward`:

```bash
# confirm the dashboard port name/number first (operator-defined)
kubectl -n risingwave get svc risingwave-meta \
  -o jsonpath='{range .spec.ports[*]}{.name}{" "}{.port}{"\n"}{end}'

kubectl -n risingwave port-forward svc/risingwave-meta 5691:5691
# then browse http://localhost:5691
```

## Rollback

```bash
kubectl delete -k manifests/risingwave/
```

Deleting the CR tells the operator to tear down the RW pods and the frontend
Service (and thus the NLB). The `postgresql-credentials` secret and the
`risingwave` namespace remain — delete them explicitly if you want a clean slate
(`kubectl delete ns risingwave` also drops the secret). RDS, the node group, and
the IAM role are Terraform-owned and untouched by this; remove them with
`terraform` if needed.

## ArgoCD on-ramp

This directory is a Kustomize target, so it's GitOps-ready as-is: an ArgoCD
`Application` with `source.path: manifests/risingwave` consumes it unchanged. The
two bootstrap steps that aren't plain declarative YAML map onto ArgoCD
mechanisms — the operator becomes its own `Application` in an earlier sync-wave
(CRD before CR), and the `postgresql-credentials` secret becomes an External
Secrets Operator `ExternalSecret` pointed at the RDS-managed Secrets Manager
entry.
