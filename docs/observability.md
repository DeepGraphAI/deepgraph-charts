# Observability

Synapse emits three signals. Metrics are scraped, logs go to stdout, traces are
pushed over OTLP.

| Signal | Endpoint | Turned on by |
|---|---|---|
| Metrics | `:8080/metrics`, Prometheus text | `observability.serviceMonitor.enabled` |
| Logs | container stdout, JSON | `server.logFormat: json` (default) |
| Traces | OTLP to a collector | `observability.otel.enabled` |
| Health | `:8080/health`, `/health/live`, `/health/ready` | always |

`examples/04-observability.yaml` turns all of this on;
`examples/observability-stack/` installs the Prometheus, Loki, Grafana and Tempo
side so the pipeline works end to end.

## Metrics

### Prometheus Operator

```yaml
observability:
  serviceMonitor:
    enabled: true
    interval: 30s
    labels:
      release: kube-prometheus-stack
```

The `labels` block is the part that goes wrong most often. Your Prometheus
selects ServiceMonitors by label, and if the selector does not match, the target
never appears and nothing says why. Check what yours wants:

```bash
kubectl get prometheus -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceMonitorSelector}{"\n"}{end}'
```

The other common cause is namespace scope: a Prometheus installed with
`serviceMonitorSelectorNilUsesHelmValues: true` (the kube-prometheus-stack
default) ignores ServiceMonitors that lack its release label even when they are
in a watched namespace. The values file in `examples/observability-stack/` sets
it to `false`.

### Without the Operator

```yaml
observability:
  podAnnotations:
    enabled: true
```

Adds `prometheus.io/scrape`, `prometheus.io/port` and `prometheus.io/path` to
the pods, for a Prometheus configured with annotation-based discovery.

### What is exported

| Family | Examples | Use |
|---|---|---|
| Query | `synapse_query_latency_seconds`, `synapse_query_total`, `synapse_query_active` | Latency and error rate |
| Search | `synapse_vector_search_*`, `synapse_text_search_*`, `synapse_hybrid_search_*` | Per-modality latency |
| Memory | `synapse_memory_rss_bytes`, `synapse_memory_vector_index_bytes`, `synapse_memory_fragmentation_ratio` | OOM avoidance |
| Storage | `synapse_storage_bytes_{read,written}_total`, `synapse_storage_operation_latency_seconds` | Disk pressure |
| Transactions | `synapse_transaction_commits_total`, `synapse_transaction_aborts_total` | Contention |
| Connections | `synapse_connections_active`, `synapse_connections_total` | Client load |
| Raft | `synapse_raft_apply_lag_seconds`, `synapse_raft_apply_errors_total`, `synapse_raft_snapshot_*` | Cluster health |
| Events | `synapse_context_events_total` | Audit and activity, by `kind` and `outcome` |

Query latency histograms carry a `query_type` label. On an instance running many
distinct query shapes that multiplies out; drop what you do not chart:

```yaml
observability:
  serviceMonitor:
    metricRelabelings:
      - sourceLabels: [__name__]
        regex: "synapse_test_.*"
        action: drop
```

### Useful queries

```promql
# p95 query latency
histogram_quantile(0.95, sum by (le) (rate(synapse_query_latency_seconds_bucket[5m])))

# Error share. The clamp keeps an idle instance at 0 rather than producing no data
sum(rate(synapse_query_total{status="error"}[5m]))
  / clamp_min(sum(rate(synapse_query_total[5m])), 0.0001)

# Memory against the container limit. Needs kube-state-metrics
synapse_memory_rss_bytes
  / on (pod) group_left kube_pod_container_resource_limits{resource="memory", container="synapse"}

# Which search modality is slow
histogram_quantile(0.95, sum by (le) (rate(synapse_hybrid_search_component_latency_seconds_bucket[5m])))

# Follower staleness, cluster only
max by (pod) (synapse_raft_apply_lag_seconds)
```

## Alerts

```yaml
observability:
  prometheusRule:
    enabled: true
    labels:
      release: kube-prometheus-stack
```

| Alert | Default | Why it matters |
|---|---|---|
| `SynapseInstanceDown` | `up == 0` for 2m | Scrape failing: crashed pod, wedged listener |
| `SynapseHighQueryLatency` | p95 > 1s for 5m | Unbounded traversal, cold cache, index pressure |
| `SynapseHighErrorRate` | > 5% for 5m | Guarded so an idle instance cannot trigger it |
| `SynapseHighMemoryUsage` | > 90% of limit for 10m | An OOM kill costs a full index rebuild |
| `SynapseSlowHybridSearch` | p95 > 0.5s for 5m | Vector index may no longer fit in memory |
| `SynapseRaftApplyLag` | > 30s for 5m | Follower reads are stale. Cluster only |
| `SynapseRaftApplyErrors` | any for 5m | Write path failing on a replica. Cluster only |

Tune a threshold, or drop an alert by disabling it:

```yaml
observability:
  prometheusRule:
    rules:
      queryLatency:
        threshold: 2      # seconds
        for: 10m
      searchLatency:
        enabled: false
```

Add your own, appended verbatim to the same group:

```yaml
observability:
  prometheusRule:
    extraRules:
      - alert: SynapseStorageWriteStall
        expr: >-
          rate(synapse_storage_bytes_written_total[5m]) == 0
          and rate(synapse_transaction_commits_total[5m]) > 0
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Committing transactions but writing no bytes"
```

`SynapseHighMemoryUsage` divides by
`kube_pod_container_resource_limits`, so it needs kube-state-metrics and a
memory limit actually set. Without both, the alert silently never fires.

## Dashboard

```yaml
observability:
  grafanaDashboard:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    folder: Synapse
```

Ships a ConfigMap that a Grafana dashboard sidecar imports. 36 panels across six
rows: Overview, Query performance, Search, Memory, Storage and transactions, and
Cluster. Namespace, release and pod are template variables, so one dashboard
covers every deployment.

If it does not show up, it is almost always one of three things: the `label` does
not match `grafana.sidecar.dashboards.label`; the sidecar is watching a single
namespace and the ConfigMap is in another (`searchNamespace: ALL` fixes it); or
the sidecar is not enabled at all.

## Logs

The server writes structured JSON to stdout by default, so any collector works
without a parsing pipeline to maintain.

```logql
{namespace="synapse", app="synapse"} | json | level = "ERROR"
{namespace="synapse", app="synapse"} | json | line_format "{{.message}}"
```

`server.logLevel: debug` on a busy instance produces a lot of lines, and log
storage is usually the expensive part of an observability stack. Keep it at
`info` outside an investigation.

`server.logFormat: text` is for reading in a terminal. It is the wrong choice
anywhere a collector is involved.

## Traces

```yaml
observability:
  otel:
    enabled: true
    endpoint: http://opentelemetry-collector.observability.svc.cluster.local:4317
    protocol: grpc
    sampleRate: 0.1
    environment: production
```

Spans cover query parsing, planning, execution and storage access, which is what
makes a "why was this query slow" question answerable rather than a guess.

`sampleRate: 1.0` exports every span. That is right for staging and wrong for a
busy production instance, where the export path becomes its own bottleneck. 0.01
to 0.1 is the usual range.

Exporting through a collector rather than straight to the trace backend means
the backend can be swapped, sampled further or fanned out without touching the
database's configuration or restarting it.

## Health endpoints

| Path | Returns | Used by |
|---|---|---|
| `/health` | 200 with version and uptime | Humans, uptime checks |
| `/health/live` | 200 while the process responds | Liveness and startup probes |
| `/health/ready` | 200, or 503 with per-component detail | Readiness probe |

`/health/ready` is the useful one when something is wrong: the 503 body names
which of storage, catalog or session manager is not up.

```bash
kubectl -n synapse exec synapse-0 -- curl -s localhost:8080/health/ready | jq
```

```json
{
  "status": "degraded",
  "checks": { "storage": "ok", "catalog": "ok", "session_manager": "error" }
}
```
