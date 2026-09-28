# Logging (`platform/logging`)

Centralized structured logs for KubeCommerce: **Grafana Alloy** collects pod
logs and ships them to **Grafana Loki**. No Promtail.

## Architecture

```
kubecommerce-{dev,staging,prod} pods (structlog JSON on stdout)
        │  Kubernetes API (pods/log)
        ▼
Alloy DaemonSet  (observability, one pod per node)
        │  enrich: namespace / pod / container / app labels
        │  parse JSON: service, level -> severity, trace_id -> structured metadata
        ▼
Loki monolithic single-binary  (observability, 5Gi filesystem PVC)
        ▲
        └── Grafana datasource (UID `loki`) — owned by lane 1 (monitoring)
```

| Component | Chart pin | Helm repo | Argo Application |
|---|---|---|---|
| Loki | `loki` **18.13.5** (Loki 3.7.8) | `https://grafana-community.github.io/helm-charts` | `platform/observability-apps/loki.yaml` (wave 0) |
| Alloy | `alloy` **1.13.0** (Alloy v1.20.0) | `https://grafana.github.io/helm-charts` | `platform/observability-apps/alloy.yaml` (wave 1) |

Values live in this directory (`loki-values.yaml`, `alloy-values.yaml`); the
Applications consume them with the Argo multi-source `$values` ref.

## DNS contract (fixed interface)

Append `/loki/api/v1/push` to `http://loki.observability.svc.cluster.local:3100`
for writes, and `/loki/api/v1/query_range` for queries. The release name is
`loki`, the namespace is `observability`, the Service port is `3100`, and
`auth_enabled=false` (no `X-Scope-OrgID`). Grafana (lane 1) points its `loki`
datasource at `http://loki.observability.svc.cluster.local:3100`.

## Query logs by `trace_id`

`trace_id` is stored as **structured metadata** (not an indexed stream label),
so it does not explode label cardinality. Query it as a pipeline filter:

```logql
# All logs for one trace
{namespace="kubecommerce-dev"} | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"

# Narrow to one service and severity
{namespace="kubecommerce-dev", service="order-service", severity="error"}
  | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"
```

Other convenient selectors from the collector config:

```logql
{namespace="kubecommerce-dev", app="gateway-api"}
{namespace="kubecommerce-prod", service="catalog-service", severity=~"warning|error"}
```

## Cross-signal correlation demo (guide Phase 10.4)

1. Grafana alert fires on high `order-service` latency.
2. Open the slow request's **trace** in Tempo (see `../tracing/README.md`).
3. Identify the slow downstream span.
4. Pivot to **logs** with the trace's `trace_id` (query above).
5. View the correlated service **metric** on the dashboards.

The Tempo→Loki pivot is wired by the Loki datasource **derived field** on
`trace_id` (links to the Tempo datasource). The Grafana **datasource objects,
their UIDs (`loki`, `tempo`, `prometheus`) and the derived field are owned by
lane 1 (monitoring)**; this lane only guarantees the endpoints, label schema and
structured metadata they depend on.
