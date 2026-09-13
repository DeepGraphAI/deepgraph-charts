# Changelog

Chart versions follow semantic versioning independently of the Synapse version
they deploy. `appVersion` tracks Synapse; `version` tracks the chart.

## 0.1.0

First release.

- StatefulSet with per-pod persistent storage, gRPC on 50051 and the HTTP
  listener (UI, REST, health, metrics) on 8080.
- Optional BOLT listener for Neo4j-compatible drivers.
- Multi-node Raft clustering, with per-pod configuration generated at start-up
  from the StatefulSet ordinal, seed-node election on ordinal 0, optional peer
  mTLS, and an admin port for `synapsectl`.
- Probes wired to `/health/live` and `/health/ready`, with a startup probe
  sized for index rebuild and first-run model downloads.
- Observability: ServiceMonitor, PrometheusRule with seven alerts, a 36-panel
  Grafana dashboard, and OTLP trace export.
- Istio `PeerAuthentication`, `Gateway`, `VirtualService` and `DestinationRule`.
  Outlier detection is deliberately omitted in cluster mode, where ejecting the
  leader would take the write path down.
- NetworkPolicy, PodDisruptionBudget, Ingress, and hooks for extra env,
  volumes, containers and manifests.
- `values.schema.json`, so a mistyped key fails at `helm install` rather than
  being silently ignored.
- Render-time guards for combinations that cannot work: no admin password,
  clustering without persistence, metrics or ingress without the HTTP listener,
  two license sources.
- Ten documented example values files, a companion observability stack, and
  eight user guides.
