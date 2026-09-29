# External Secrets Operator — AWS delivery wiring

This directory holds the **cloud-only** External Secrets Operator (ESO)
manifests. ESO reads AWS Secrets Manager and materialises the same
`<service>-secrets` Kubernetes Secrets that the app Helm chart consumes
(`charts/kubecommerce/values.yaml` → `secretEnvFrom`). It is the AWS
counterpart of the local, out-of-band `make k8s-secrets` workflow
(`scripts/k8s-dev-secrets.sh`).

Nothing here is needed for the local kind cluster: `make k8s-secrets` still
creates those Secrets directly, and the Argo CD Applications in
`platform/cloud-apps/` are deliberately **manual-sync**, so this path is inert
on kind.

```text
platform/external-secrets/
├── README.md                              # this file
├── cluster-secret-store.yaml              # ClusterSecretStore `aws-secretsmanager`
└── overlays/
    ├── dev/external-secrets.yaml          # 5 app ExternalSecrets (dev prefix)
    ├── staging/external-secrets.yaml      # 5 app ExternalSecrets (staging prefix)
    └── prod/external-secrets.yaml         # 5 app ExternalSecrets (prod prefix)
```

Argo CD wiring (see `argocd/platform-apps/platform-cloud.yaml`):

| Application | Chart / path | Wave | Sync |
|---|---|---|---|
| `external-secrets` | Helm `external-secrets` `2.11.0` (`https://charts.external-secrets.io`) | 0 | manual |
| `external-secrets-manifests` | `platform/external-secrets` (recurse) | 1 | manual |

The wave-0 chart installs the `external-secrets.io` CRDs; the wave-1 app then
applies the `ClusterSecretStore` + the per-environment `ExternalSecret`s.

## How ESO works here

1. `ClusterSecretStore/aws-secretsmanager` describes **how** to reach AWS
   (region + workload identity). It is cluster-scoped: one per cluster.
2. Each `ExternalSecret` names a **target** Kubernetes Secret (matching the
   app chart's `secretEnvFrom` name) and a list of `secretKey` ← `remoteRef.key`
   mappings.
3. ESO fetches each referenced Secrets Manager entry and writes the Kubernetes
   Secret with `creationPolicy: Owner` (ESO owns/updates it; deleting the
   ExternalSecret deletes the Secret).
4. Pods mount the Secret via `envFrom.secretRef` at container start.

## Prerequisites (Terraform outputs)

These are produced by the EKS/Terraform path and are **not** in this repo:

| Output | Used for | Where to set it |
|---|---|---|
| `region` | `ClusterSecretStore.spec.provider.aws.region` | replace `<aws-region>` in `cluster-secret-store.yaml` |
| secret prefix | Secrets Manager path convention | already `/<env>/kubecommerce/...`; adjust if your prefix differs |
| ESO IAM role ARN | Pod Identity / IRSA source | see below |
| `gateway_dns` / domain | TLS hostname | `platform/gateway/gateway.yaml`, `platform/cert-manager/README.md` |

### Workload identity (no static AWS keys)

**Default here: EKS Pod Identity.** Terraform creates an
`aws_eks_pod_identity_association` for ServiceAccount `external-secrets` in
namespace `external-secrets` (the ESO controller SA created by the pinned Helm
chart). With Pod Identity the store needs **no `auth` block at all**: the AWS
SDK inside ESO resolves temporary credentials from the node's Pod Identity
Agent. Per the ESO docs, `auth.jwt.serviceAccountRef` is an **IRSA-only**
mechanism and must not be combined with Pod Identity.

**Alternative: IRSA.** Do not create the Pod Identity association; instead
annotate the ESO ServiceAccount with
`eks.amazonaws.com/role-arn: <eks_eso_role_arn>` and add this block under
`spec.provider.aws` in `cluster-secret-store.yaml` (it is shown commented
there):

```yaml
auth:
  jwt:
    serviceAccountRef:
      name: external-secrets
      namespace: external-secrets
```

The role needs only
`secretsmanager:GetSecretValue` + `secretsmanager:DescribeSecret` on the
`/<env>/kubecommerce/*` secret ARNs. No long-lived access keys ever enter
Kubernetes or Git.

### AppProject (owner: Argo CD bootstrap)

`argocd/project.yaml` must allow:

* `sourceRepos`: `https://charts.external-secrets.io` and
  `https://aws.github.io/eks-charts` (AWS Load Balancer Controller); the
  cert-manager source is documented in `platform/cert-manager/README.md`.
* `destinations`: namespaces `external-secrets`, `cert-manager` and
  `platform-system` (in-cluster server).

The resource kinds are already whitelisted (`ClusterSecretStore`,
`ExternalSecret`, plus the chart's CRDs/RBAC/webhooks/Deployment).

## Key naming convention

```text
/<env>/kubecommerce/<area>/<name>          # env = dev | staging | prod
```

The `Secret`/key mapping materialised in `kubecommerce-<env>`:

| Kubernetes Secret | Key | AWS Secrets Manager path |
|---|---|---|
| `auth-service-secrets` | `AUTH_DATABASE_URL` | `/<env>/kubecommerce/database/auth-url` |
| `auth-service-secrets` | `AUTH_JWT_PRIVATE_KEY` | `/<env>/kubecommerce/auth/jwt-signing-key` |
| `catalog-service-secrets` | `CATALOG_DATABASE_URL` | `/<env>/kubecommerce/database/catalog-url` |
| `catalog-service-secrets` | `CATALOG_REDIS_URL` | `/<env>/kubecommerce/redis/catalog-url` |
| `catalog-service-secrets` | `CATALOG_INTERNAL_API_TOKEN` | `/<env>/kubecommerce/internal/api-token` |
| `order-service-secrets` | `ORDERS_DATABASE_URL` | `/<env>/kubecommerce/database/orders-url` |
| `order-service-secrets` | `ORDERS_RABBITMQ_URL` | `/<env>/kubecommerce/rabbitmq/orders-url` |
| `order-service-secrets` | `ORDERS_INTERNAL_API_TOKEN` | `/<env>/kubecommerce/internal/api-token` |
| `notification-worker-secrets` | `WORKER_RABBITMQ_URL` | `/<env>/kubecommerce/rabbitmq/worker-url` |
| `notification-worker-secrets` | `WORKER_REDIS_URL` | `/<env>/kubecommerce/redis/worker-url` |
| `gateway-api-secrets` | `GATEWAY_REDIS_URL` | `/<env>/kubecommerce/redis/gateway-url` |
| `gateway-api-secrets` | `GATEWAY_INTERNAL_API_TOKEN` | `/<env>/kubecommerce/internal/api-token` |

These **12 Kubernetes keys resolve from 10 distinct AWS Secrets Manager
paths**: `internal/api-token` is shared by the three
`*_INTERNAL_API_TOKEN` keys, and every other key has its own path. (The AWS
path list is owned by the Terraform lane; it no longer includes
`rabbitmq/password` — the two RabbitMQ URLs above are stored as whole
connection strings.)

Values are stored as **whole connection strings** (the app reads full URLs via
`envFrom`), e.g.

```text
/dev/kubecommerce/database/auth-url =
  postgresql+asyncpg://kubecommerce:<password>@<rds-endpoint>:5432/auth_db
```

**Shared internal token:** the app currently reuses one internal token for
gateway → order and order → catalog, so all three `*_INTERNAL_API_TOKEN` keys
resolve from the single entry `/<env>/kubecommerce/internal/api-token`
(one rotation keeps them equal).

## Rotation and reload

* `refreshInterval: 1h` — ESO re-reads Secrets Manager at least hourly and
  rewrites the Kubernetes Secret when the value changes.
* Rotate the value in AWS Secrets Manager (new DB password / JWT key / token).
* Running pods do **not** hot-reload `envFrom` variables. Restart them to pick
  up the new Secret:

  ```bash
  kubectl -n kubecommerce-<env> rollout restart deploy
  kubectl -n kubecommerce-<env> rollout status  deploy
  ```

  (A restart, not a rebuild — this is the guide's Phase 6.3 rotation test.)
* Stopping the rollout before all pods are restarted keeps the old password
  valid until the backing store rotates, so rotate store-side first, restart
  second.

## Exporter secrets (optional)

`observability/postgres-exporter-secret` (`DATA_SOURCE_NAME`) and
`observability/redis-exporter-secret` (`redis-password`) are **not** generated
per environment: the `observability` namespace is shared by the whole cluster,
so three per-env ExternalSecrets would fight over the same target Secret.
Add them once, in the cluster that actually runs the managed database, e.g.:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: postgres-exporter-secret
  namespace: observability
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-secretsmanager, kind: ClusterSecretStore }
  target: { name: postgres-exporter-secret, creationPolicy: Owner }
  data:
    - secretKey: DATA_SOURCE_NAME
      remoteRef: { key: /<env>/kubecommerce/database/postgres-exporter-dsn }
```

`redis-exporter-secret` is analogous with key `redis-password` from
`/<env>/kubecommerce/redis/password`.

> These two exporter paths are **outside the 10 application paths** in the
> table above; add matching Secrets Manager entries only if the exporters are
> actually wired on the cloud cluster.

## Enabling on AWS (checklist)

1. Replace `<aws-region>` in `cluster-secret-store.yaml`.
2. Create the 10 Secrets Manager entries per environment under
   `/dev|staging|prod/kubecommerce/…` (see the table above).
3. Ensure the AppProject allows the `charts.external-secrets.io` and
   `eks-charts` source repos plus the `external-secrets` / `platform-system`
   destinations.
4. Manually sync the `external-secrets` Application (wave 0), the
   `aws-load-balancer-controller` Application (wave 0; without it the Gateway
   Service never gets an NLB), then `external-secrets-manifests` (wave 1).
5. Verify:

   ```bash
   kubectl -n external-secrets get pods
   kubectl get clustersecretstore aws-secretsmanager \
     -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
   kubectl -n kubecommerce-prod get externalsecret
   kubectl -n kubecommerce-prod get secret auth-service-secrets \
     -o jsonpath='{.data.AUTH_DATABASE_URL}' | base64 -d
   ```
