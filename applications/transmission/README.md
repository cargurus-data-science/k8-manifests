# Transmission Helm chart

**One chart for every Transmission service.** Not N charts for N services — that's
a locked architectural decision (CLAUDE.md, *"One Helm chart, parameterized via
values files"*). The chart in this directory is parameterized entirely by
`chart/values/<service>-<env>.yaml` overlays.

```
chart/
  Chart.yaml                 chart metadata (version bumps on template changes)
  values.yaml                the SCHEMA + safe defaults — read this first
  .helmignore
  templates/
    _helpers.tpl             name/label/SA helpers (keyed off service.name)
    deployment.yaml
    service.yaml
    ingress.yaml             external-dns + ALB annotations (see below)
    hpa.yaml
    pdb.yaml                 auto-skips for single-replica services
    serviceaccount.yaml      Pod Identity — NO role-arn annotation (see below)
    configmap.yaml           plain env (secrets come from External Secrets)
    networkpolicy.yaml
    NOTES.txt
  values/
    dashboard-backend-dev.yaml
    dashboard-frontend-dev.yaml
    mesh-dev.yaml            defined for completeness; not deployed until mesh-deploy
```

## The convention in one line

> A service is `service.name` + an image + a values file. Everything the cluster
> creates for it (Deployment, Service, Ingress, HPA, PDB, ConfigMap,
> NetworkPolicy, ServiceAccount) is derived from that one values file layered
> over `values.yaml`.

Each install names its Helm **release** after the service:

```bash
helm upgrade --install dashboard-backend chart/ \
  --namespace transmission --create-namespace \
  --values chart/values/dashboard-backend-dev.yaml
```

`chart/values.yaml` is the implicit base (Helm always reads it); the
`--values` file is the per-service-per-env overlay on top.

## How to add a new service — mechanical

1. **Build context already exists** — `services/<svc>/` with a `Dockerfile`
   (that's the service engineer's PR, not this chart's).
2. **Add one values file:** `chart/values/<svc>-<env>.yaml`. Set at minimum:
   - `service.name`, `service.port`
   - `image.repository` (CG ECR: `457497801237.dkr.ecr.us-east-1.amazonaws.com/transmission/<svc>`)
   - `serviceAccount.name` — **must match** the DS-2795 Pod Identity association
     (see below)
   - `ingress.*` if the service is public, else `ingress.enabled: false`
   - probe paths if they differ from the defaults
3. **Add it to the deploy matrix** — one entry in `.github/workflows/deploy.yml`
   under `resolve` for the target env.
4. Done. No template edits, no new chart.

Verify before opening the PR:

```bash
helm lint chart/ --values chart/values/<svc>-<env>.yaml
helm template chart/ --values chart/values/<svc>-<env>.yaml
```

## Pod Identity wiring (NOT IRSA)

The cluster (`transmission-runtime`, DS-2795) runs **EKS Pod Identity** with
`enable_irsa = false` and **no OIDC provider**. That changes how a pod gets an
IAM role versus the classic IRSA pattern:

| | IRSA (not used here) | Pod Identity (this cluster) |
|---|---|---|
| Binding mechanism | `eks.amazonaws.com/role-arn` annotation on the SA | `aws_eks_pod_identity_association` resource, control-plane-side |
| Chart's responsibility | render the role ARN annotation | create an SA with the right **(namespace, name)** |
| Role ARN visible to chart | yes | **no** — invisible to the pod |

So `templates/serviceaccount.yaml` carries **no role-arn annotation**. The chart's
only job is to create a ServiceAccount whose `(namespace, name)` matches what
DS-2795 associated. The IAM role is bound by the control plane; the pod never
sees the ARN.

**Which values key maps to which DS-2795 association:**

| Values key | Must equal DS-2795's | 
|---|---|
| `namespace` (chart-level, default `transmission`) | `aws_eks_pod_identity_association.namespace` |
| `serviceAccount.name` (per service) | `aws_eks_pod_identity_association.service_account` |

`service.name` (the resource handle — Deployment/Service/Ingress/OTEL/ECR repo)
and `serviceAccount.name` (the Pod Identity binding key) are **deliberately
separate values.** They can differ, and for the dashboard they do:

| Service (`service.name`) | `serviceAccount.name` (DS-2795 binding) | Namespace |
|---|---|---|
| `dashboard-backend` | `dashboard-be` | `transmission` |
| `dashboard-frontend` | `dashboard-fe` | `transmission` |
| `mesh` | `mesh` | `transmission` |

> ⚠️ **Reconcile at merge.** These SA names come from the DS-2797 brief
> amendment. DS-2795 is in flight in parallel; if its README documents different
> names, the values files must match **DS-2795's README** (it owns the
> associations). If a name is wrong, Pod Identity silently fails to bind and the
> pod's AWS calls get no credentials — there is no deploy-time error. This is the
> one cross-PR coupling to verify before the first real deploy (DS-2798).

## Ingress: external-dns + ALB (both from DS-2795)

DS-2795 stands up two cluster controllers the chart's Ingress relies on:

- **external-dns** (private Route 53 zone, `policy=sync`) watches Ingresses and
  creates the A-record from
  `external-dns.alpha.kubernetes.io/hostname`.
- **AWS Load Balancer Controller** provisions an ALB from the `alb.ingress.*`
  annotations.

`templates/ingress.yaml` surfaces these through values:

| Values key | Annotation / field | Notes |
|---|---|---|
| `ingress.hostname` | `external-dns.../hostname` + rule host | external-dns makes the DNS record from this |
| `ingress.scheme` | `alb.ingress.../scheme` | `internal` for CG dev |
| `ingress.targetType` | `alb.ingress.../target-type` | `ip` — ALB routes straight to pod IPs |
| `ingress.groupName` | `alb.ingress.../group.name` | **shared ALB** — see below |
| `ingress.groupOrder` | `alb.ingress.../group.order` | rule precedence within the group |
| `ingress.healthcheckPath` | `alb.ingress.../healthcheck-path` | must 200 on the pod (see below) |
| `ingress.certificateArn` | `alb.ingress.../certificate-arn` + listen-ports | empty ⇒ HTTP-only |
| `ingress.servicePortName` | rule `backend.service.port.name` | empty ⇒ route to `service.port` by number; set ⇒ route to a named `service.extraPorts` entry (see below) |

### Multi-port pods (`service.extraPorts`)

A service normally has exactly one port: `service.port`, rendered as the
container port, the Service port, and the Ingress backend. `service.extraPorts`
adds more, for a workload whose image starts **more than one server in one
process tree** — today only `hindsight`, whose vendor image runs its API on 8888
and a Next.js operator console on 9999.

```yaml
service:
  port: 8888
  extraPorts:
    - name: console     # DNS-1123 label, ≤15 chars (k8s port-name limit)
      port: 9999
ingress:
  servicePortName: console   # front the console, not the API
```

Each entry renders a containerPort, a Service port of the **same name**, and a
NetworkPolicy allow. `targetPort` is the port *name*, so the Deployment and
Service cannot drift. `[]` (the default) renders nothing — every other service is
byte-identical.

Honoured only when `service.exposePort` is true, and never on the
`cronjob.enabled` branch (no pod, no Service).

> **Why not a second Helm release per port?** Tried first; it does not work.
> `transmission.selectorLabels` pins `app.kubernetes.io/instance: {{ .Release.Name }}`,
> so a second release either renders a whole second pod — for `hindsight` a 4.2GB
> vendor image with a duplicate `HINDSIGHT_API_WORKER_ID`, the orphaned-task bug
> that env var exists to prevent — or, if `service.name` is reused, a Service whose
> `instance` label matches no pod and which has **zero endpoints**. One pod with
> additional ports is the standard Kubernetes shape.

### Shared ALB (the dashboard runs on one)

The dashboard is a **single hostname** serving two services: backend at `/api`,
frontend at `/`. Both Ingresses set the same `ingress.groupName`
(`transmission-dashboard`), so the ALB controller provisions **one** ALB and
path-routes between them. Without a shared group.name you'd get two ALBs
fighting over one external-dns A-record. `groupOrder` orders the rules: backend
`/api` (10) is matched before the frontend catch-all `/` (20).

> ⚠️ **ALB-level annotations must agree across group members.** `scheme`,
> `listen-ports`, `certificate-arn`, and `ssl-redirect` apply to the whole ALB,
> not a single rule — if the backend and frontend values disagree, the
> controller reports a group conflict and stops reconciling. So when DS-2798
> provisions the ACM cert, set `ingress.certificateArn` to the **same** value in
> *both* `dashboard-backend-dev.yaml` and `dashboard-frontend-dev.yaml` (and keep
> `scheme` identical). Per-rule annotations (`healthcheck-path`, `group.order`,
> the path itself) are free to differ.

### ALB health checks (target-type=ip gotcha)

With `target-type: ip` the ALB health-checks **pod IPs directly**, not a
path the Ingress understands. The dashboard backend mounts everything under
`/api`, so a default `/` health check would 404 and mark every target unhealthy.
Hence `ingress.healthcheckPath: /api/health/live` in the backend values. The
frontend serves `/` (200 from nginx), so it uses the default.

### ACM certificate (HTTP-only until DS-2798)

`ingress.certificateArn` is empty in the committed values: the ACM cert is
per-service-per-deploy and is provisioned by **DS-2798**, not at chart time. With
it empty the ALB listens on `:80` only; set it and the ALB also listens on `:443`
and redirects `80→443`.

## How the deploy workflow triggers

`.github/workflows/deploy.yml` runs `helm upgrade --install` per service per env.

- **Trigger:** push to `main` touching `chart/**`, or manual `workflow_dispatch`
  with an `environment` (dev/prod) and optional `image_tag` override.
- **What it does:** assume an AWS role via GitHub **OIDC** (no static keys) →
  `aws eks update-kubeconfig` → `helm upgrade --install … --atomic --wait`.
- **What it does NOT do:** build or push images (separate concern; ECR repos are
  DS-2795's), and it never holds `contents:write` or package scopes — permissions
  are locked to `contents: read` + `id-token: write`.
- **Dormant until DS-2798:** every job is gated on `vars.DEPLOY_ENABLED == 'true'`.
  DS-2798 sets that plus `AWS_DEPLOY_ROLE_ARN`, `AWS_REGION`, `EKS_CLUSTER_NAME`
  and wires the cluster/secrets. Until then the workflow is a no-op on merge (no
  red X, no AWS calls).
- **Service↔env mapping** lives in the `resolve` job. Adding a service to an env
  is one line there + the values file. `mesh` is intentionally absent until
  `feat/mesh-deploy`.

## Secrets

The chart never templates secret *values*. `envFromSecret` names a Kubernetes
Secret populated from AWS Secrets Manager out of band. Plain (non-secret) config
goes in `env:` and is rendered into a ConfigMap.

### ⚠ Rotating a key: `helm upgrade` alone does NOT roll the pods

`envFrom.secretRef` values are read **once, at pod start**. `checksum/config`
hashes `.Values.env` only — nothing hashes the Secret, because the chart does not
render it and Helm cannot see its contents at template time.

So rotating a key and running `helm upgrade` with unchanged values gives you a
byte-identical pod template, no new ReplicaSet, a pod still holding the **old**
credential — and `helm upgrade` exits 0 reporting success. Caught live
2026-08-11: a pod served happily with a credential for a DB role that had just
been dropped, and looked perfectly healthy doing it.

**Do both of these on any rotation:**

1. **Bump `secretVersion`** in the service's values file to any new string
   (e.g. `"2026-08-11-cp-key"`). It is hashed into a pod annotation, so the
   change alone forces a roll — and it records the rotation in git.
2. **`kubectl rollout restart deploy/<svc>`.** Unconditional backstop; does not
   depend on anyone remembering step 1.

Blast radius if you skip both: every service using `envFromSecret`. Nine releases
share `mesh-secrets` (`mesh`, `standup-socket`, `review-sweep`, `standup-beat`,
`checkpoint-reaper`, `queue-scan`, `reconcile-orphans`, `learning-consolidation`,
`skill-import`), plus `dashboard-backend-secrets`, `edge-backend-secrets` and
`hindsight-secrets`.

**CronJobs are exempt** — every tick creates a fresh pod that reads the Secret as
it is then, so a stale-credential CronJob cannot happen. Verified on
`review-sweep`: successive ticks produce distinct pods. That is why
`cronjob.yaml` carries no checksum annotation, and it is not an oversight.

## Scope boundaries (what this chart is NOT)

- **No IRSA roles, no ECR repos** — those are DS-2795 (`transmission-runtime`).
- **No actual deploy / cluster connect / kubeconfig secrets** — DS-2798.
- **No mesh service code** — a later PR (`feat/mesh-deploy`).
- **No Argo CD / GitOps controller** — locked out; deploy is helm-via-CI, period.
