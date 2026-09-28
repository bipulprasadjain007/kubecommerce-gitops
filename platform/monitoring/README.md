# KubeCommerce monitoring (`platform/monitoring`)

Phase E lane 1: the Kubernetes monitoring stack (Prometheus Operator, Prometheus,
Alertmanager, Grafana, kube-state-metrics, node-exporter), the local alert sink,
KubeCommerce PrometheusRules and the Grafana dashboards.

```
platform/monitoring/
├── README.md                        # this file
├── kps-values.yaml                  # kube-prometheus-stack 91.5.3 values
├── alert-sink/
│   ├── configmap-script.yaml        # stdlib Python webhook receiver
│   ├── deployment.yaml
│   └── service.yaml
├── rules/
│   └── kubecommerce-alerts.yaml     # 2 PrometheusRules, 8 alerts
└── dashboards/
    ├── kubecommerce-red.json        # JSON ConfigMap manifests (see below)
    ├── kubecommerce-workloads.json
    └── kubecommerce-messaging.json

platform/observability-apps/
├── kube-prometheus-stack.yaml       # Argo CD Application (sync-wave 0)
├── dashboards.yaml                  # Argo CD Application (sync-wave 1)
├── monitoring-alert-sink.yaml       # Argo CD Application (sync-wave 1) -> platform/monitoring/alert-sink
└── monitoring-rules.yaml            # Argo CD Application (sync-wave 1) -> platform/monitoring/rules
```

All four Applications are child Applications of
`argocd/platform-apps/platform-observability.yaml` (wave -3), which recurses over
`platform/observability-apps`. Each target directory has its own explicit
single-path Application (never a directory glob over `platform/monitoring`, so
future sibling directories cannot be pulled in accidentally):

| Application | Path | Deploys |
|---|---|---|
| `kube-prometheus-stack` | Helm chart (+ `$values/platform/monitoring/kps-values.yaml`) | Prometheus/Alertmanager/Grafana/exporters |
| `kubecommerce-monitoring-dashboards` | `platform/monitoring/dashboards` | Grafana dashboard ConfigMaps |
| `monitoring-alert-sink` | `platform/monitoring/alert-sink` | Alertmanager webhook receiver |
| `monitoring-rules` | `platform/monitoring/rules` | KubeCommerce PrometheusRules |

Lane 2 adds the Loki/Tempo/OTel Applications to the same directory.

## What is deployed

| Component | Namespace | Release / object | Notes |
|---|---|---|---|
| Prometheus Operator | `monitoring` | `kube-prometheus-stack` | chart 91.5.3 (operator 0.94.1) |
| Prometheus | `monitoring` | `kube-prometheus-stack-prometheus` | 1 replica, 6h / 5GiB, WAL compression |
| Alertmanager | `monitoring` | `kube-prometheus-stack-alertmanager` | 1 replica, severity routes -> alert sink |
| Grafana | `monitoring` | `kube-prometheus-stack-grafana` | sidecar dashboards + datasources |
| kube-state-metrics | `monitoring` | subchart | workload/HPA/restart metrics |
| node-exporter | `monitoring` | subchart (DaemonSet) | node metrics |
| Alert sink | `observability` | `alert-sink` Deployment/Service | configmap-mounted stdlib Python |
| KubeCommerce alerts | `observability` | 2 x PrometheusRule | 8 alerts with severity + runbook |
| Dashboards | `observability` | 3 x ConfigMap | `grafana_dashboard: "1"`, folder `KubeCommerce` |

Control-plane scrapers (`kubeEtcd`, `kubeControllerManager`, `kubeScheduler`,
`kubeProxy`) are disabled: a local kind cluster does not expose them the way the
chart expects. `kubeStateMetrics` and `nodeExporter` stay enabled.

All Prometheus/Alertmanager selectors are **open** (`{}` with the matching
`*NilUsesHelmValues: false` and empty namespace selectors), so ServiceMonitors,
PodMonitors and PrometheusRules in every namespace (including the app
ServiceMonitors in `kubecommerce-dev|staging|prod`) are discovered. An empty
selector means "everything"; a null selector would mean "nothing / own namespace".
No selector is ever null.

## Fixed interfaces (other Phase E lanes depend on these)

| Interface | Value |
|---|---|
| Helm release / namespace | `kube-prometheus-stack` in `monitoring` |
| Prometheus service | `kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` |
| Alertmanager service | `kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093` |
| Grafana service | `kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80` |
| Prometheus datasource | url `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`, uid `prometheus` |
| Loki datasource | url `http://loki.observability.svc.cluster.local:3100`, uid `loki` |
| Tempo datasource | url `http://tempo.observability.svc.cluster.local:3200`, uid `tempo` |
| Alert sink endpoint | `http://alert-sink.observability.svc.cluster.local:8080/alerts` |
| App metrics | `kubecommerce_http_requests_total{service,method,route,status}`, `kubecommerce_http_request_duration_seconds_bucket{service,method,route}`, `kubecommerce_http_requests_in_flight{service}` |

Do not rename any of these without coordinating with the Loki/Tempo/dashboards
lanes. The Loki and Tempo services are owned by lane 2; until they exist the two
datasources appear "unreachable" but the Prometheus dashboard panels still work.

### Cross-signal wiring

- Loki has a derived field on `trace_id` (JSON log lines) that opens Tempo.
- Tempo has `tracesToLogsV2` (-> Loki), `tracesToMetrics` (-> Prometheus) and
  `serviceMap` (-> Prometheus), enabling the guide Step 10.4 cross-signal demo.
- Prometheus has exemplar links on `trace_id` to Tempo.

## Required AppProject change (owner: Argo CD bootstrap lane)

`argocd/project.yaml` currently whitelists only this GitOps repository in
`spec.sourceRepos`. The `kube-prometheus-stack` Application pulls a Helm chart
from `https://prometheus-community.github.io/helm-charts`, so **that URL must be
added to `sourceRepos`** or Argo CD rejects the Application. The observability
resource kinds (`Prometheus`, `Alertmanager`, `Grafana`, `ThanosRuler`, ...) and
the cluster-scoped `ClusterRole`/`ClusterRoleBinding`/webhook configurations are
already in the project's allow-lists as of the Phase E prep pass; verify they are
present before syncing. (Out of scope for this lane, which may only write
`platform/monitoring/**` and the two `platform/observability-apps/*` files.)

## Adding an alert

1. Add a rule to a group in `rules/kubecommerce-alerts.yaml` (or a new
   `PrometheusRule` file in `rules/`).
2. Give it `labels.severity` (`critical` or `warning`) so the Alertmanager route
   picks a child route, plus `annotations.summary`, `annotations.description` and
   `annotations.runbook_url`.
3. Use the real metric names:
   - app: `kubecommerce_http_requests_total`, `kubecommerce_http_request_duration_seconds_bucket`, `kubecommerce_http_requests_in_flight`
   - workloads: `kube_pod_container_status_restarts_total`, `kube_deployment_status_replicas_unavailable`, `container_memory_working_set_bytes`, `kube_pod_container_resource_limits`, `kube_horizontalpodautoscaler_status_current_replicas`, `kube_horizontalpodautoscaler_spec_max_replicas`
   - RabbitMQ (built-in `rabbitmq_prometheus` plugin): `rabbitmq_queue_messages`, `rabbitmq_global_messages_received_total`, `rabbitmq_global_messages_acknowledged_total`
   - PostgreSQL/Redis: `pg_stat_activity_count`, `pg_settings_max_connections`, `redis_keyspace_hits_total`, `redis_keyspace_misses_total`
4. `kubectl -n observability apply -f rules/` (or let Argo sync). Prometheus
   reloads rules automatically; check `/rules` on the Prometheus UI.

The namespace is `observability`; the open `ruleSelector`/`ruleNamespaceSelector`
means no label is needed for discovery.

## Adding a dashboard

The dashboards are **Kubernetes ConfigMap manifests authored in JSON syntax**
(not bare Grafana JSON) so that a single file is simultaneously valid JSON, a
valid ConfigMap for `kubeconform`, and directly applicable by Argo CD; the
dashboard JSON is the escaped string under `data["<uid>.json"]`.

1. Copy `dashboards/kubecommerce-red.json`, change `metadata.name`,
   `data` key (`<new-uid>.json`) and the dashboard `uid`/`title`/`panels`.
2. Keep `metadata.labels.grafana_dashboard: "1"` and
   `metadata.annotations.grafana_folder: "KubeCommerce"`, and set the panel /
   target datasource to `{"type": "prometheus", "uid": "prometheus"}`.
3. Validate JSON + manifest, then let Argo sync or `kubectl -n observability apply -f dashboards/`.
   The Grafana dashboard sidecar (`searchNamespace: ALL`) loads it within ~30s.

To refresh a dashboard from the Grafana UI: export the JSON, replace the string in
`data`, and commit. Do not edit dashboards in the UI and expect persistence —
`allowUiUpdates` is false.

## Reaching Grafana / Alertmanager / Prometheus locally

```bash
export PATH="$HOME/.local/bin:$PATH"

# Grafana (admin password):
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000

# Alertmanager UI (see active alerts / silences / the local-webhook receiver):
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093

# Prometheus UI (targets, rules, service discovery):
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090

# Alert sink:
kubectl -n observability port-forward svc/alert-sink 8080:8080
curl -s localhost:8080/health
curl -s localhost:8080/alerts | python3 -m json.tool
curl -s -X DELETE localhost:8080/alerts
```

Fire a test alert and watch it resolve (guide Phase 9 exit criterion):

```bash
# Port-forward the sink, then simulate an Alertmanager webhook:
curl -s -X POST localhost:8080/alerts -H 'Content-Type: application/json' \
  -d '{"version":"4","status":"firing","receiver":"local-webhook","groupKey":"{}:{alertname=\"Demo\"}","alerts":[{"status":"firing","labels":{"alertname":"Demo","severity":"warning","namespace":"kubecommerce-dev"}}]}'
kubectl -n observability logs deployment/alert-sink --tail=20
```

## Validation (static, no cluster required)

```bash
export PATH="$HOME/.local/bin:$PATH"
cd kubecommerce-gitops

# Plain manifests (CRDs skipped):
kubeconform -strict -summary -ignore-missing-schemas \
  platform/monitoring/rules/kubecommerce-alerts.yaml \
  platform/monitoring/alert-sink/ platform/monitoring/dashboards/ \
  platform/observability-apps/

# Dashboard JSON validity + ConfigMap YAML validity:
python3 - <<'PY'
import json, pathlib, yaml
for p in pathlib.Path('platform/monitoring/dashboards').rglob('*.json'):
    json.loads(p.read_text()); print(p, 'ok')
for p in pathlib.Path('platform/monitoring/dashboards').glob('*.yaml'):
    list(yaml.safe_load_all(p.read_text())); print(p, 'ok')
PY

# Chart render against the pinned version:
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 91.5.3 -n monitoring -f platform/monitoring/kps-values.yaml --skip-crds \
  | kubeconform -strict -summary -ignore-missing-schemas | tail -3
```

## What must be verified on a live cluster

- AppProject `sourceRepos` includes the prometheus-community Helm repo (see above).
- `helm template` proves the values apply; a live sync proves the CRDs install and
  the Prometheus/Alertmanager/Grafana pods become Ready on kind 1.36.x.
- The app ServiceMonitors resolve (requires Phase D app chart `serviceMonitor.enabled: true`
  in each environment overlay, which the Phase E promotion must turn on).
- The alert sink receives a real Alertmanager notification and `send_resolved`
  delivers the resolved event.
- Loki/Tempo datasources resolve once lane 2 deploys those Services; PostgreSQL and
  Redis panels populate once the postgres-exporter/redis-exporter from lane 2 scrape
  the `platform-system` StatefulSets.
- `kube_horizontalpodautoscaler_*` / `container_memory_working_set_bytes` series
  exist (kube-state-metrics + cAdvisor are enabled in this stack).
