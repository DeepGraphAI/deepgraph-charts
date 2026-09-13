# Synapse Helm charts

Helm charts for deploying [Synapse](https://github.com/deepgraphai/Synapse), a
graph + vector hybrid database that speaks ISO GQL.

```bash
helm repo add synapse https://deepgraphai.github.io/synapse-helm
helm repo update

helm install synapse synapse/synapse \
  --namespace synapse --create-namespace \
  --set auth.password="$(openssl rand -base64 24)"
```

## What gets deployed

A StatefulSet with per-pod persistent storage, a ClusterIP Service for clients,
a headless Service for stable pod DNS, and the ConfigMaps and Secret the server
reads at start-up. Optional pieces - Ingress, ServiceMonitor, PrometheusRule,
Grafana dashboard, NetworkPolicy, PodDisruptionBudget and Istio routing - are
off by default and turned on individually.

| Port | Protocol | Carries |
|---|---|---|
| 50051 | gRPC | The primary client API |
| 8080 | HTTP | Bundled web UI, REST API, `/health`, `/metrics` |
| 7687 | BOLT | Neo4j-compatible drivers (off by default) |
| 5701 | gRPC | Raft replication (cluster mode only) |
| 5702 | gRPC | Admin API for `synapsectl` (cluster mode only) |

## Requirements

- Kubernetes 1.23 or newer
- Helm 3.8 or newer
- A StorageClass that can provision `ReadWriteOnce` volumes
- For cluster mode: three or more nodes, and a Secret holding Raft mTLS material

## Examples

`examples/` holds complete, commented values files. Each one is a working
starting point rather than a fragment.

| File | For |
|---|---|
| [01-minimal.yaml](examples/01-minimal.yaml) | Smallest install that works |
| [02-single-node-production.yaml](examples/02-single-node-production.yaml) | One node, sized and locked down |
| [03-ha-cluster.yaml](examples/03-ha-cluster.yaml) | Three-node Raft cluster |
| [04-observability.yaml](examples/04-observability.yaml) | Metrics, logs and traces |
| [05-service-mesh.yaml](examples/05-service-mesh.yaml) | Istio, mTLS and gateway routing |
| [06-ingress-tls.yaml](examples/06-ingress-tls.yaml) | Public UI behind an Ingress |
| [07-air-gapped.yaml](examples/07-air-gapped.yaml) | Private registry, no egress |
| [08-ai-embeddings.yaml](examples/08-ai-embeddings.yaml) | In-database embeddings and extraction |
| [09-bolt-drivers.yaml](examples/09-bolt-drivers.yaml) | Neo4j-compatible driver access |
| [10-local-dev.yaml](examples/10-local-dev.yaml) | kind, minikube, k3d |

[examples/observability-stack/](examples/observability-stack/) additionally
installs the Prometheus, Loki, Grafana and Tempo side of example 04, so the
whole pipeline works end to end without assembling it yourself.

## Documentation

| Guide | Covers |
|---|---|
| [Installation](docs/installation.md) | Prerequisites, install, upgrade, uninstall |
| [Configuration](docs/configuration.md) | Every value, grouped by what it affects |
| [Clustering](docs/clustering.md) | Raft, quorum, scaling, mTLS, admin operations |
| [Storage](docs/storage.md) | Volume sizing, StorageClass choice, backups |
| [Observability](docs/observability.md) | Metrics, alerts, dashboards, logs, traces |
| [Security](docs/security.md) | Credentials, network policy, mesh, hardening |
| [Service mesh](docs/service-mesh.md) | Istio specifics, gRPC and BOLT through a mesh |
| [Troubleshooting](docs/troubleshooting.md) | Symptoms, causes and fixes |

## Two things to decide before installing

**`auth.password`** has no default. The chart refuses to render without either
`auth.password` or `auth.existingSecret`, because a database that ships with a
known password and reachable ports is not a useful default. In anything beyond
a laptop, use `auth.existingSecret` so the password does not end up in a values
file or in Helm release history.

**`ml.models`** defaults to `none`, which means no model downloads and a pod
that is ready in under a minute. Graph traversal, vector search over embeddings
you supply, and full-text search all work in that mode. Set it to `all` or a
subset only if you need Synapse to compute embeddings or run extraction itself,
and read [example 08](examples/08-ai-embeddings.yaml) first - first start then
takes 15-30 minutes and needs egress.

## Replicas are not redundancy unless cluster mode is on

Synapse replicates through Raft, not through a shared volume. Setting
`replicaCount: 3` with `cluster.enabled: false` gives three independent
databases behind one Service, and a client gets different data depending on
which pod it lands on. The chart prints a warning when it sees that
combination. See [docs/clustering.md](docs/clustering.md).

## Development

```bash
helm lint charts/synapse --set auth.password=test
helm template t charts/synapse --set auth.password=test | kubeconform -strict -ignore-missing-schemas
helm unittest charts/synapse          # if helm-unittest is installed
```

Render every example and validate the output:

```bash
./scripts/validate.sh
```

## License

These charts are distributed under the same terms as Synapse itself. The
software they deploy requires a valid license for the tier you configure - see
`tier.licenseKey` in [docs/configuration.md](docs/configuration.md).
