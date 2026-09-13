# Example values files

Each file here is a complete values file, not a fragment: pass one to
`helm install -f` and you get a working deployment. They are commented with the
reasoning behind each setting, so they double as a second form of documentation.

```bash
helm install synapse synapse/synapse \
  -n synapse --create-namespace \
  -f examples/02-single-node-production.yaml
```

Combine a base example with your own overrides by passing both; later files win:

```bash
helm install synapse synapse/synapse -n synapse \
  -f examples/02-single-node-production.yaml \
  -f my-overrides.yaml
```

## Which one to start from

| File | Topology | Storage | Exposure | Models |
|---|---|---|---|---|
| `01-minimal.yaml` | 1 pod | 50Gi | ClusterIP | none |
| `02-single-node-production.yaml` | 1 pod | 500Gi SSD | ClusterIP + NetworkPolicy | none |
| `03-ha-cluster.yaml` | 3-node Raft | 500Gi SSD each | ClusterIP + NetworkPolicy | none |
| `04-observability.yaml` | 1 pod | 200Gi | ClusterIP | none |
| `05-service-mesh.yaml` | 1 pod | 200Gi | Istio gateway, mTLS | none |
| `06-ingress-tls.yaml` | 1 pod | 200Gi | Ingress with TLS | none |
| `07-air-gapped.yaml` | 1 pod | 500Gi | ClusterIP, no egress | none |
| `08-ai-embeddings.yaml` | 1 pod | 500Gi + 80Gi | ClusterIP | all |
| `09-bolt-drivers.yaml` | 1 pod | 200Gi | ClusterIP, BOLT on | none |
| `10-local-dev.yaml` | 1 pod | ephemeral | port-forward | none |

Decision shortcuts:

- **Evaluating it** - `01-minimal.yaml`, or `10-local-dev.yaml` on a laptop cluster.
- **First real deployment** - `02-single-node-production.yaml`. Add clustering later; it is a `helm upgrade`, not a reinstall.
- **Cannot tolerate a restart window** - `03-ha-cluster.yaml`.
- **Already run Prometheus and Grafana** - layer `04-observability.yaml` on top of your base file.
- **Application teams reach it over a mesh** - `05-service-mesh.yaml`.
- **Need embeddings computed inside the database** - `08-ai-embeddings.yaml`, and read the timing note first.

## They are meant to be edited

Every example that is not `01` or `10` references resources you have to create
yourself:

| Referenced | Create with |
|---|---|
| `synapse-admin` Secret | `kubectl create secret generic synapse-admin --from-literal=SYNAPSE_USER=admin --from-literal=SYNAPSE_PASSWORD=...` |
| `synapse-license` Secret | `kubectl create secret generic synapse-license --from-literal=SYNAPSE_LICENSE_KEY=...` |
| `synapse-cluster-tls` Secret | See [docs/clustering.md](../docs/clustering.md) |
| `storageClass: gp3` | Whatever SSD class your cluster actually has - check `kubectl get storageclass` |
| `release: kube-prometheus-stack` label | Whatever your Prometheus selects on |
| `synapse.example.com` | Your hostname |

A render is the fastest way to check you have substituted everything:

```bash
helm template synapse synapse/synapse -n synapse -f examples/03-ha-cluster.yaml | less
```

## Companion stack

`observability-stack/` installs Prometheus, Loki, Grafana, Tempo and an OTLP
collector configured to work with `04-observability.yaml`. Skip it if you
already run those; you only need to match the ServiceMonitor's `release:` label
to your own Prometheus selector.
