# synapse

Deploys [Synapse](https://github.com/deepgraphai/Synapse), a graph + vector
hybrid database speaking ISO GQL, as a StatefulSet with persistent per-pod
storage.

```bash
helm repo add synapse https://deepgraphai.github.io/synapse-helm
helm install synapse synapse/synapse \
  --namespace synapse --create-namespace \
  --set auth.password="$(openssl rand -base64 24)"
```

## Requirements

| | |
|---|---|
| Kubernetes | 1.23+ |
| Helm | 3.8+ |
| Storage | A StorageClass provisioning `ReadWriteOnce` |

## Objects created

Always: `StatefulSet`, `Service`, headless `Service`, `ServiceAccount`, two
`ConfigMap`s, and a `Secret` unless `auth.existingSecret` is set.

Optional, each behind its own value: `Ingress`, `NetworkPolicy`,
`PodDisruptionBudget`, `ServiceMonitor`, `PrometheusRule`, dashboard
`ConfigMap`, and Istio `Gateway` / `VirtualService` / `DestinationRule` /
`PeerAuthentication`. Cluster mode adds a bootstrap `ConfigMap`.

## Ports

| Port | Protocol | Carries | Default |
|---|---|---|---|
| 50051 | gRPC | Primary client API | always on |
| 8080 | HTTP | UI, REST, `/health`, `/metrics` | on |
| 7687 | BOLT | Neo4j-compatible drivers | off |
| 5701 | gRPC | Raft replication | cluster mode |
| 5702 | gRPC | Admin API for `synapsectl` | cluster mode |

## Values

The authoritative reference is [values.yaml](values.yaml), which documents every
key inline, and [docs/configuration.md](../../docs/configuration.md), which
groups them by what they affect. The table below is the short version of what
you are most likely to change.

| Value | Default | |
|---|---|---|
| `image.repository` | `synapse` | Registry path |
| `image.tag` | `""` | Empty means the chart's appVersion |
| `replicaCount` | `1` | See the note below |
| `auth.password` | `""` | **Required** unless `auth.existingSecret` |
| `auth.existingSecret` | `""` | Preferred over an inline password |
| `tier.level` | `enterprise` | Gates available features |
| `ml.models` | `none` | `none`, `all`, or a subset |
| `persistence.data.size` | `50Gi` | Immutable after install |
| `persistence.data.storageClass` | `""` | Cluster default if empty |
| `resources.limits.memory` | `8Gi` | The value that matters most |
| `server.http.enabled` | `true` | Probes and metrics depend on it |
| `server.http.debugEndpoints` | `false` | Unauthenticated when on |
| `server.bolt.enabled` | `false` | |
| `cluster.enabled` | `false` | Raft replication |
| `ingress.enabled` | `false` | HTTP listener only |
| `networkPolicy.enabled` | `false` | |
| `observability.serviceMonitor.enabled` | `false` | Prometheus Operator |
| `observability.otel.enabled` | `false` | Trace export |
| `serviceMesh.istio.enabled` | `false` | |

## Two defaults worth knowing

**`auth.password` has none.** The chart refuses to render without it or
`auth.existingSecret`. A database that ships with a known password on reachable
ports is not a useful default.

**`ml.models` is `none`.** No model downloads, so the pod is ready in under a
minute. Graph traversal, vector search over embeddings you supply, and full-text
search all work. Set it to `all` or a subset only if Synapse itself needs to
compute embeddings or run extraction - first start then takes 15-30 minutes and
needs egress.

## Replicas are not redundancy on their own

Synapse replicates through Raft, not through a shared volume. `replicaCount: 3`
with `cluster.enabled: false` is three independent databases behind one Service,
and a client gets different data depending on which pod it reaches. The chart
warns when it sees that combination. See
[docs/clustering.md](../../docs/clustering.md).

## Validation built into the chart

These combinations are refused at render time rather than producing a broken
deployment:

- `auth.password` and `auth.existingSecret` both unset
- `cluster.enabled` without `persistence.data.enabled`
- `observability.serviceMonitor.enabled` or `ingress.enabled` without
  `server.http.enabled`
- `tier.licenseKey` and `tier.existingLicenseSecret` both set

## Testing

```bash
helm test synapse -n synapse
```

Runs a pod that checks `/health`, `/health/ready` and `/metrics` from inside the
cluster.
