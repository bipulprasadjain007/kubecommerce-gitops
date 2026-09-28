# Tracing (`platform/tracing`)

Distributed tracing for KubeCommerce: services export OTLP to the
**OpenTelemetry Collector**, which forwards traces to **Grafana Tempo**.

## Architecture

```
kubecommerce-{dev,staging,prod} pods (OpenTelemetry SDK, OTLP/HTTP)
        │  http://otel-collector.observability.svc.cluster.local:4318
        ▼
OpenTelemetry Collector  (observability, 1-replica Deployment)
        │  processors: memory_limiter -> batch
        │  exporter:   otlp_grpc/tempo (insecure)
        ▼
Tempo single-binary  (observability, 5Gi PVC, 24h retention)
        ▲
        └── Grafana datasource (UID `tempo`) — owned by lane 1 (monitoring)
```

| Component | Chart pin | Helm repo | Argo Application | Values |
|---|---|---|---|---|
| Tempo | `tempo` **3.0.0** (Tempo 3.0.3) | `https://grafana-community.github.io/helm-charts` | `platform/observability-apps/tempo.yaml` (wave 0) | `platform/tracing/tempo-values.yaml` |
| OTel Collector | `opentelemetry-collector` **0.173.1** (collector 0.160.0) | `https://open-telemetry.github.io/opentelemetry-helm-charts` | `platform/observability-apps/otel-collector.yaml` (wave 1) | `platform/observability/otel-collector-values.yaml` |

> Tempo 3.x removed the 2.x `ingester` (now `live_store`) and `compactor` (now
> `backend_scheduler`/`backend_worker`, owner of `retention`). There is **no
> downgrade path** from 3.x to 2.x — see the header of `tempo-values.yaml`.

## DNS contract (fixed interface)

- Apps: `http://otel-collector.observability.svc.cluster.local:4318` (OTLP/HTTP).
  The collector Service also exposes `4317` (OTLP/gRPC).
- Collector → Tempo: `tempo.observability.svc.cluster.local:4317` (gRPC, insecure).
- Tempo Service (`tempo.observability.svc.cluster.local`): `3200` HTTP API/query,
  `4317` OTLP gRPC, `4318` OTLP HTTP. Grafana (lane 1) uses `http://tempo.observability.svc.cluster.local:3200`.

Label contract for the collector (the app chart's NetworkPolicy egress peer
matches namespace `observability` + pod label `app.kubernetes.io/name: otel-collector`
on port `4318`): the Pod and Service carry `app.kubernetes.io/name: otel-collector`
and `app.kubernetes.io/part-of: kubecommerce`.

## Cross-signal correlation demo (guide Phase 10.4)

1. Grafana alert fires on high `order-service` latency (metrics, lane 1).
2. Open the slow request's trace in **Tempo** and find the slow downstream span.
3. Pivot to **logs** in Loki using the span's `trace_id`
   (see `../logging/README.md` for the LogQL query).
4. View the correlated service metric.

The Loki→Tempo pivot is the `trace_id` **derived field** on the Loki datasource;
both datasource objects and their UIDs (`prometheus`, `loki`, `tempo`) are owned
by **lane 1 (monitoring)**. This lane guarantees the endpoints, the `trace_id`
structured-metadata schema and the OTLP pipeline they rely on.
