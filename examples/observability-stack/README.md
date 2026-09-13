# Observability stack

A working Prometheus + Loki + Grafana + Tempo deployment for Synapse, assembled
from upstream community charts. Nothing here is Synapse-specific infrastructure:
the point is to give you a stack that already has the right scrape config,
datasources and log pipeline so `examples/04-observability.yaml` works end to end
on the first try.

If you already run kube-prometheus-stack and Loki, skip this directory and go
straight to `examples/04-observability.yaml` - you only need to match the
`release:` label the ServiceMonitor carries to whatever your Prometheus selects
on.

## What each piece does

| Component | Role | Reached at |
|---|---|---|
| Prometheus | Scrapes `:8080/metrics`, evaluates the alert rules | `prometheus-operated:9090` |
| Grafana | Dashboards over all three signals | `grafana:80` |
| Loki | Log storage, queried from Grafana | `loki:3100` |
| Promtail | Ships pod stdout to Loki | DaemonSet, no service |
| Tempo | Trace storage, queried from Grafana | `tempo:3200` |
| OTEL Collector | Receives OTLP from Synapse, forwards to Tempo | `opentelemetry-collector:4317` |

Synapse emits to two of these directly - Prometheus scrapes it, and it pushes
OTLP spans to the collector. Logs are picked up from the container's stdout, so
there is nothing to configure on the Synapse side beyond `server.logFormat=json`.

## Install

```bash
kubectl create namespace observability

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Metrics, alerting and Grafana itself.
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability -f kube-prometheus-stack.values.yaml

# Logs.
helm install loki grafana/loki -n observability -f loki.values.yaml
helm install promtail grafana/promtail -n observability -f promtail.values.yaml

# Traces.
helm install tempo grafana/tempo -n observability -f tempo.values.yaml
helm install opentelemetry-collector open-telemetry/opentelemetry-collector \
  -n observability -f otel-collector.values.yaml

# Finally, Synapse itself.
helm install synapse synapse/synapse -n synapse -f ../04-observability.yaml
```

## Verify

```bash
# Prometheus is scraping Synapse - the target should be "up".
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
open http://localhost:9090/targets

# Grafana, with the Synapse dashboard already imported.
kubectl -n observability get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
open http://localhost:3000
```

The Synapse dashboard lands in the folder named `Synapse`. If it is missing, the
sidecar did not pick up the ConfigMap: check that
`observability.grafanaDashboard.label` matches
`grafana.sidecar.dashboards.label` in the Grafana release, and that the
ConfigMap is in a namespace the sidecar watches
(`sidecar.dashboards.searchNamespace`).

## Useful queries

Metrics, in Prometheus or a Grafana panel:

```promql
# p95 query latency
histogram_quantile(0.95, sum by (le) (rate(synapse_query_latency_seconds_bucket[5m])))

# Error share, guarded against an idle instance
sum(rate(synapse_query_total{status="error"}[5m]))
  / clamp_min(sum(rate(synapse_query_total[5m])), 0.0001)

# Memory against the container limit
synapse_memory_rss_bytes
  / on (pod) group_left kube_pod_container_resource_limits{resource="memory", container="synapse"}

# Follower lag, cluster deployments only
max by (pod) (synapse_raft_apply_lag_seconds)
```

Logs, in Grafana's Loki explorer. JSON output means no parser config:

```logql
{namespace="synapse", app_kubernetes_io_name="synapse"} | json | level = "ERROR"

# Slow queries, if the field is present in the log line
{namespace="synapse"} | json | duration_ms > 1000
```

Traces: open a Tempo query in Grafana and filter on `service.name = synapse`. The
dashboard's exemplar links jump from a latency spike straight to a matching
trace, provided Prometheus was built with exemplar storage on (it is in the
values file here).

## Notes on cost

The two things that get expensive are log volume and histogram cardinality.

- `server.logLevel: debug` on a busy instance produces a lot of lines. Keep it
  at `info` outside of an investigation.
- `synapse_query_latency_seconds_bucket` carries a `query_type` label. On an
  instance running many distinct query shapes this multiplies out; the
  `metricRelabelings` block in `04-observability.yaml` is where to drop what you
  do not chart.
- `observability.otel.sampleRate` at `1.0` exports every span. Production
  deployments generally want 0.01 to 0.1.
