# Shared in-cluster infrastructure (`platform-system`)

Plain, pinned Kubernetes manifests for the three shared backing services the five
KubeCommerce services need to run in the **local kind cluster**:

| Component | Workload | Image (pinned) | Service name | Ports | Storage |
|---|---|---|---|---|---|
| PostgreSQL 16 | `StatefulSet/postgres` | `postgres:16-alpine` | `postgres` | `5432` | 5Gi PVC (`volumeClaimTemplates`) |
| Redis 7 | `StatefulSet/redis` | `redis:7-alpine` | `redis` | `6379` | 2Gi PVC |
| RabbitMQ 3.13 | `StatefulSet/rabbitmq` | `rabbitmq:3.13-management-alpine` | `rabbitmq` | `5672` amqp, `15672` management, `15692` prometheus | 2Gi PVC |

All resources live in the pre-created `platform-system` namespace
(`platform/namespaces/namespaces.yaml`). No Bitnami/Helm chart dependency and no
mutable image tags: these are plain manifests, one resource per file.

```
platform/infrastructure/
├── README.md                     # this file
├── secret.example.yaml           # EXAMPLE ONLY - never applied/committed with real values
├── apps/
│   ├── postgres-application.yaml # Argo CD Application (sync-wave -1)
│   ├── redis-application.yaml
│   └── rabbitmq-application.yaml
├── postgres/
│   ├── configmap-init.yaml       # creates auth_db, catalog_db, orders_db on first boot
│   ├── service.yaml              # Service `postgres`
│   └── statefulset.yaml
├── redis/
│   ├── service.yaml              # Service `redis`
│   └── statefulset.yaml
└── rabbitmq/
    ├── configmap-enabled-plugins.yaml  # [rabbitmq_management,rabbitmq_prometheus].
    ├── service.yaml                    # Service `rabbitmq`
    ├── servicemonitor.yaml             # monitoring.coreos.com/v1, :15692, 15s
    └── statefulset.yaml
```

## DNS names (fixed interface)

Applications reach the backing services at these exact in-cluster DNS names:

| Backing service | DNS name |
|---|---|
| PostgreSQL | `postgres.platform-system.svc.cluster.local:5432` |
| Redis | `redis.platform-system.svc.cluster.local:6379` |
| RabbitMQ (AMQP) | `rabbitmq.platform-system.svc.cluster.local:5672` |
| RabbitMQ (management UI/API) | `rabbitmq.platform-system.svc.cluster.local:15672` |
| RabbitMQ (Prometheus) | `rabbitmq.platform-system.svc.cluster.local:15692` |

The Service names must never change (the app chart's `<service>-secrets` URLs
depend on them). Short names also work inside the cluster:
`postgres:5432`, `redis:6379`, `rabbitmq:5672`.

### App chart values that must point here

The app Helm chart does not carry database/broker URLs (they are Secret values).
When creating the per-service Secrets, use URLs of this shape:

```text
AUTH_DATABASE_URL      postgresql+asyncpg://kubecommerce:<postgres-password>@postgres.platform-system.svc.cluster.local:5432/auth_db
CATALOG_DATABASE_URL   postgresql+asyncpg://kubecommerce:<postgres-password>@postgres.platform-system.svc.cluster.local:5432/catalog_db
ORDERS_DATABASE_URL    postgresql+asyncpg://kubecommerce:<postgres-password>@postgres.platform-system.svc.cluster.local:5432/orders_db
CATALOG_REDIS_URL      redis://:<redis-password>@redis.platform-system.svc.cluster.local:6379/0
WORKER_REDIS_URL       redis://:<redis-password>@redis.platform-system.svc.cluster.local:6379/1
GATEWAY_REDIS_URL      redis://:<redis-password>@redis.platform-system.svc.cluster.local:6379/2
ORDERS_RABBITMQ_URL    amqp://kubecommerce:<rabbitmq-password>@rabbitmq.platform-system.svc.cluster.local:5672/
WORKER_RABBITMQ_URL    amqp://kubecommerce:<rabbitmq-password>@rabbitmq.platform-system.svc.cluster.local:5672/
```

(Redis logical databases match `docs/architecture.md` section 4: `/0` catalog,
`/1` worker, `/2` gateway. The RabbitMQ default user is `kubecommerce`.)

## Credentials and the secret

All three components read one Secret, `kubecommerce-infra-secrets`, with keys
`postgres-password`, `redis-password`, `rabbitmq-password`. Nothing secret is
committed. Per guide Step 6.1 ("generated Kubernetes Secrets excluded from Git"),
create it out of band before syncing the Applications:

```bash
export PATH="$HOME/.local/bin:$PATH"
kubectl -n platform-system create secret generic kubecommerce-infra-secrets \
  --from-literal=postgres-password="$(openssl rand -base64 24)" \
  --from-literal=redis-password="$(openssl rand -base64 24)" \
  --from-literal=rabbitmq-password="$(openssl rand -base64 24)"
```

`secret.example.yaml` documents the same shape but is **EXAMPLE ONLY** and must
not be applied with real values. If you prefer apply-then-replace, apply it once
and immediately overwrite with generated values, e.g.:

```bash
kubectl -n platform-system create secret generic kubecommerce-infra-secrets \
  --from-literal=postgres-password="$(openssl rand -base64 24)" \
  --from-literal=redis-password="$(openssl rand -base64 24)" \
  --from-literal=rabbitmq-password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Rotating credentials

- **Redis**: change the Secret value and delete the pod
  (`kubectl -n platform-system delete pod redis-0`) - the new password is applied
  on start (the AOF is unaffected).
- **PostgreSQL / RabbitMQ**: the official images apply the credential **only on a
  fresh/empty data directory** (`POSTGRES_PASSWORD` on first init; RabbitMQ's
  `RABBITMQ_DEFAULT_USER/PASS` on first boot). To rotate on an existing volume,
  update the Secret and then rotate inside the app (`ALTER ROLE ... PASSWORD`
  for PostgreSQL; `rabbitmqctl change_password kubecommerce <new>` for RabbitMQ).
  Simply changing the Secret and restarting does nothing for existing data.

## Storage classes

The `volumeClaimTemplates` intentionally omit `storageClassName`, so the
**cluster's default StorageClass** is used:

- **kind**: the default is `standard` (the bundled `local-path-provisioner`).
  It provisions `ReadWriteOnce` local volumes from the node's filesystem.
- **EKS**: the default is usually `gp3` (or `gp2`). Persistent volumes attach to
  a single Availability Zone, which constrains StatefulSet rescheduling; for a
  single-replica portfolio setup this is acceptable.

To pin a class explicitly, uncomment `storageClassName: <name>` in each
`volumeClaimTemplates` entry (a documented edit; no overlay/kustomize layer is
introduced). Sizes: PostgreSQL `5Gi`, Redis `2Gi`, RabbitMQ `2Gi`.

## Deploying

The three Argo CD `Application`s in `apps/` target `platform-system`, use
`path: platform/infrastructure/<component>`, `directory.recurse: true`,
sync-wave `-1`, `ServerSideApply=true` and `SkipDryRunOnMissingResource=true`,
with automated `prune` + `selfHeal` for dev:

```bash
kubectl -n argocd apply -f platform/infrastructure/apps/   # or include via the app-of-apps
```

For a quick manual smoke test without Argo CD:

```bash
kubectl apply -f platform/infrastructure/postgres/
kubectl apply -f platform/infrastructure/redis/
kubectl apply -f platform/infrastructure/rabbitmq/
kubectl -n platform-system get statefulset,svc,pvc
```

> Note: `secret.example.yaml`, being at `platform/infrastructure/` (not inside a
> component directory), is not picked up by any Application's `directory.recurse`
> path and is never applied by Argo CD.

## Teardown / reset

```bash
# Remove the Argo CD Applications (cascades to their resources in platform-system)
kubectl -n argocd delete application kubecommerce-postgres kubecommerce-redis kubecommerce-rabbitmq

# Or delete the workloads directly; PVCs are NOT deleted by StatefulSet removal
kubectl -n platform-system delete statefulset postgres redis rabbitmq
kubectl -n platform-system delete svc postgres redis rabbitmq
kubectl -n platform-system delete configmap postgres-init rabbitmq-enabled-plugins rabbitmq-conf
kubectl -n platform-system delete servicemonitor rabbitmq
```

`volumeClaimTemplates` PVCs (`data-postgres-0`, `data-redis-0`,
`data-rabbitmq-0`) persist after workload deletion (data safety). Wipe them for a
true reset:

```bash
kubectl -n platform-system delete pvc data-postgres-0 data-redis-0 data-rabbitmq-0
```

A full `kind delete cluster` removes everything; use the repo's
`scripts/kind-down.sh` for that.

## EKS / staging / prod

These in-cluster StatefulSets are for the **local kind** environment and the dev
portfolio demo. In staging/prod, managed services replace them:

| Local (this directory) | AWS replacement |
|---|---|
| PostgreSQL StatefulSet | Amazon RDS / Aurora PostgreSQL |
| Redis StatefulSet | Amazon ElastiCache for Redis |
| RabbitMQ StatefulSet | Amazon MQ for RabbitMQ |

For managed services: disable/remove the three `apps/*-application.yaml`
Applications and point the per-service Secrets at the managed endpoints. In
staging/prod also turn off automated sync (no `selfHeal`/`prune`, or manual sync)
so infrastructure changes are reviewed. Credentials should come from AWS Secrets
Manager via External Secrets Operator (guide Step 6.2), never from
`secret.example.yaml`.

## Interfaces depended on elsewhere

- **Service names** must remain exactly `postgres`, `redis`, `rabbitmq`.
- **NetworkPolicy**: the app chart's default-deny egress rules select these pods
  by label (`charts/kubecommerce/values.yaml` `global.networkPolicy`). The pod
  templates and Services therefore carry:
  - PostgreSQL: `app.kubernetes.io/name: postgresql`
  - Redis: `app.kubernetes.io/name: redis`
  - RabbitMQ: `app.kubernetes.io/name: rabbitmq`
  - all: `app.kubernetes.io/part-of: kubecommerce`

  Do not rename these labels without updating the chart's peer selectors.
- **ServiceMonitor**: `rabbitmq/servicemonitor.yaml` is scraped by the Phase E
  kube-prometheus-stack (open `serviceMonitorSelector`), port `prometheus`,
  path `/metrics`, interval `15s`. See "RabbitMQ metrics" below.

## RabbitMQ metrics

The `rabbitmq_prometheus` plugin exposes metrics on `:15692`, scraped by
`servicemonitor.yaml` at **`/metrics`**.

By default the plugin returns only **aggregate** metrics there. Per-object
series — for example
`rabbitmq_queue_messages{queue="kubecommerce.notifications.order-created"}` and
the matching `.dlq` series — are returned only when RabbitMQ is started with:

```text
prometheus.return_per_object_metrics = true
```

That setting lives in `rabbitmq/configmap-rabbitmq-conf.yaml` and is mounted at
`/etc/rabbitmq/rabbitmq.conf` (subPath). **The DLQ alert and the queue-depth
dashboard panels depend on it**: with the flag left `false`, the per-queue series
are absent from `/metrics` and those queries are empty.

Cardinality trade-off: per-object metrics grow with the number of queues,
connections and channels, increasing scrape payload and Prometheus series count.
On this single-queue portfolio broker that is negligible; on a large broker leave
the flag off and instead scrape the plugin's dedicated `/metrics/per-object`
endpoint on a separate, lower-frequency job.

The ServiceMonitor deliberately stays on `/metrics` (not `/metrics/per-object`):
the config flag makes `/metrics` include the per-object series, so one scrape
covers both the aggregate and per-object panels. If the flag is ever turned off,
switch the ServiceMonitor `path` to `/metrics/per-object` (and accept that
aggregate metrics then need a second job on `/metrics`).

## Validation (static, no cluster required)

```bash
export PATH="$HOME/.local/bin:$PATH"
cd kubecommerce-gitops
kubeconform -strict -summary -ignore-missing-schemas platform/infrastructure/
python3 - <<'PY'
import yaml, pathlib
for p in pathlib.Path('platform/infrastructure').rglob('*.yaml'):
    list(yaml.safe_load_all(p.read_text()))
    print(p, 'ok')
PY
```

ServiceMonitor and the Argo CD `Application`s are custom resources and are
skipped by kubeconform with `-ignore-missing-schemas`.
