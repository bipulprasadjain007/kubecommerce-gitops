# Prometheus exporters (`observability` namespace)

Two upstream Helm charts that turn the shared backing services (PostgreSQL and
Redis, deployed by `platform/infrastructure/`) into Prometheus-scrapable metrics.
They exist so the lane-1 Grafana dashboard **"KubeCommerce - Messaging & Data"**
(`platform/monitoring/dashboards/kubecommerce-messaging.json`) has data for its
PostgreSQL and Redis panels.

```
platform/exporters/
├── README.md                          # this file
├── postgres-exporter-values.yaml      # prometheus-postgres-exporter 8.2.0 values
└── redis-exporter-values.yaml         # prometheus-redis-exporter 6.31.1 values
```

The Argo CD `Application`s that consume these values live in
`platform/observability-apps/` (wave 1, applied by the
`kubecommerce-platform-observability` app-of-apps):

| Application | Chart (version) | Repo | Release | Namespace |
|---|---|---|---|---|
| `postgres-exporter` | `prometheus-postgres-exporter` **8.2.0** (appVersion v0.20.1) | `https://prometheus-community.github.io/helm-charts` | `postgres-exporter` | `observability` |
| `redis-exporter` | `prometheus-redis-exporter` **6.31.1** (appVersion v1.91.1) | `https://prometheus-community.github.io/helm-charts` | `redis-exporter` | `observability` |

Both use the multi-source `$values` pattern (first source = values-only checkout
of this repo, second source = remote chart reading the values through `$values`),
`ServerSideApply=true` and `SkipDryRunOnMissingResource=true`, sync-wave `1`.

## What each exporter scrapes

### PostgreSQL (`postgres-exporter`)

- Target: `postgres.platform-system.svc.cluster.local:5432` (Service `postgres`
  from `platform/infrastructure/postgres/`).
- Connection: user `kubecommerce`, database `postgres`, `sslmode=disable`.
- Endpoint: `:9187 /metrics` (chart default), exposed on Service port `http` (80).
- Default-enabled collectors used by dashboard C:
  - `stat_activity` → `pg_stat_activity_count` (labels incl. `datname`)
  - `settings` → `pg_settings_max_connections`
  - `stat_database` → `pg_stat_database_*` (per-database counters)
- Other default families include `pg_up`, `pg_stat_bgwriter_*`,
  `pg_postmaster_*`, `pg_roles_*`, `pg_replication_*`, `pg_locks_*`.

### Redis (`redis-exporter`)

- Target: `redis.platform-system.svc.cluster.local:6379` (Service `redis` from
  `platform/infrastructure/redis/`).
- Endpoint: `:9121 /metrics`, Service port `redis-exporter`.
- The exporter mirrors Redis `INFO` sections; the families dashboard C uses:
  - `redis_keyspace_hits_total`
  - `redis_keyspace_misses_total`
  - `redis_commands_processed_total`
- Also exposes `redis_up`, `redis_connected_clients`, `redis_memory_used_bytes`,
  `redis_db_keys`, etc.

## Secret names and keys (never in Git)

The exporters run in `observability`, so they get **dedicated** Secrets there
instead of reading `platform-system/kubecommerce-infra-secrets` directly. Both
are created out-of-band by `scripts/k8s-dev-secrets.sh` (`make k8s-secrets
ENV=dev`) and are idempotent (`--dry-run=client | kubectl apply`).

| Secret (namespace `observability`) | Key | Consumed via |
|---|---|---|
| `postgres-exporter-secret` | `DATA_SOURCE_NAME` | chart `config.datasourceSecret` → env `DATA_SOURCE_NAME` (`secretKeyRef`) |
| `redis-exporter-secret` | `redis-password` | chart `auth.secret` → env `REDIS_PASSWORD` (`secretKeyRef`), `auth.enabled: true` |

Values written by the script:

```text
postgres-exporter-secret/DATA_SOURCE_NAME =
  postgresql://kubecommerce:<postgres-password>@postgres.platform-system.svc.cluster.local:5432/postgres?sslmode=disable
redis-exporter-secret/redis-password = <redis-password>
```

where `<postgres-password>` / `<redis-password>` are the generated keys of
`platform-system/kubecommerce-infra-secrets` (persisted once in the git-ignored
`.secrets/k8s-<env>-passwords.env`; see `platform/infrastructure/README.md`).

The Redis **address** is not sensitive and stays in values
(`redisAddress: redis://redis.platform-system.svc.cluster.local:6379`); only the
password is sourced from the Secret. The PostgreSQL connection string contains
the password and is therefore stored whole in the Secret rather than assembled
in the values file.

## ServiceMonitor contract

kube-prometheus-stack is configured with **open** selectors
(`serviceMonitorSelector: {}`, `serviceMonitorSelectorNilUsesHelmValues: false`,
`serviceMonitorNamespaceSelector: {}` — see `platform/monitoring/kps-values.yaml`),
so Prometheus discovers every ServiceMonitor in every namespace. **No `release`
label is required** on these exporters.

Rendered (namespace `observability`):

| ServiceMonitor | Service | Port | Path | Interval |
|---|---|---|---|---|
| `postgres-exporter` | `postgres-exporter` (80 → 9187) | `http` | `/metrics` | 30s |
| `redis-exporter` | `redis-exporter` (9121) | `redis-exporter` | `/metrics` | 30s |

Grafana datasource UID `prometheus` (pinned by lane 1) queries these families by
name only; no lane-1 dashboard edits are needed for the contract.

### `helm template` note

`prometheus-redis-exporter` guards its ServiceMonitor with
`.Capabilities.APIVersions.Has "monitoring.coreos.com/v1"`. Plain
`helm template` (no cluster) omits it, so if you want to render the
ServiceMonitor locally add `--api-versions monitoring.coreos.com/v1`. Under Argo
CD (and on a live cluster with the Prometheus Operator CRDs present) it is
created normally.

## How `make k8s-secrets` supplies credentials

```bash
export PATH="$HOME/.local/bin:$PATH"
make k8s-secrets ENV=dev      # -> bash scripts/k8s-dev-secrets.sh dev
```

The script:

1. requires a reachable cluster and the `platform-system`, `kubecommerce-dev`
   and `observability` namespaces (created by `make kind-up`);
2. loads/generates the passwords (git-ignored `.secrets/k8s-<env>-passwords.env`);
3. applies `platform-system/kubecommerce-infra-secrets` and the five
   `<service>-secrets`;
4. applies the two exporter Secrets in `observability` described above.

Secrets are never printed. To rotate, delete the passwords file and re-run, then
`kubectl -n observability rollout restart deploy postgres-exporter redis-exporter`.

## Validation (static, no cluster required)

```bash
export PATH="$HOME/.local/bin:$PATH"
cd kubecommerce-gitops
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update

helm template postgres-exporter prometheus-community/prometheus-postgres-exporter \
  --version 8.2.0 -n observability \
  -f platform/exporters/postgres-exporter-values.yaml \
  | kubeconform -strict -summary -ignore-missing-schemas

helm template redis-exporter prometheus-community/prometheus-redis-exporter \
  --version 6.31.1 -n observability \
  -f platform/exporters/redis-exporter-values.yaml \
  | kubeconform -strict -summary -ignore-missing-schemas

kubeconform -strict -summary -ignore-missing-schemas \
  platform/observability-apps/postgres-exporter.yaml \
  platform/observability-apps/redis-exporter.yaml

bash -n ../scripts/k8s-dev-secrets.sh
```

The Argo CD `Application`s are custom resources and are skipped by kubeconform
with `-ignore-missing-schemas`.
