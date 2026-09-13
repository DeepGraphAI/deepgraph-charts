# Troubleshooting

## First commands

```bash
kubectl -n synapse get pods,pvc,svc
kubectl -n synapse describe pod synapse-0
kubectl -n synapse logs synapse-0 --tail=200
kubectl -n synapse logs synapse-0 --previous        # after a crash
kubectl -n synapse exec synapse-0 -- curl -s localhost:8080/health/ready | jq
```

`/health/ready` is the most informative of these when the pod is running but not
serving: the 503 body names which component is down.

---

## Install fails before anything is created

### `set auth.password or auth.existingSecret`

Working as intended. The chart will not render without an admin password.

```bash
helm install synapse synapse/synapse -n synapse \
  --set auth.password="$(openssl rand -base64 24)"
```

Better, for anything real:

```bash
kubectl -n synapse create secret generic synapse-admin \
  --from-literal=SYNAPSE_USER=admin \
  --from-literal=SYNAPSE_PASSWORD="$(openssl rand -base64 24)"
helm install synapse synapse/synapse -n synapse --set auth.existingSecret=synapse-admin
```

### `cluster.enabled requires persistence.data.enabled`

A Raft log that does not survive a restart is not a Raft log. Enable
persistence, or turn off cluster mode.

### `... requires server.http.enabled`

The ServiceMonitor scrapes `/metrics` and the Ingress serves the UI, both of
which live only on the HTTP listener. Enable it, or turn off whichever feature
you asked for.

---

## Pod never becomes ready

### Pending

```bash
kubectl -n synapse describe pod synapse-0 | grep -A10 Events
```

| Message | Cause |
|---|---|
| `pod has unbound immediate PersistentVolumeClaims` | No StorageClass, or the named one does not exist. `kubectl get storageclass` |
| `Insufficient memory` / `Insufficient cpu` | Requests exceed what any node has free |
| `didn't match pod anti-affinity rules` | Fewer nodes than replicas with `podAntiAffinity.type: hard` |

### CrashLoopBackOff

```bash
kubectl -n synapse logs synapse-0 --previous
```

| Symptom in the log | Cause | Fix |
|---|---|---|
| Killed with no error, exit 137 | OOM | Raise `resources.limits.memory`. See below |
| `FATAL: this image cannot run a multi-node cluster` | The image lacks the `cluster` build feature | Rebuild with `--features cluster`, or set `cluster.enabled=false`. See below |
| Stalls installing Python packages, then killed | `ml.enabled` with no egress, or too small a startup budget | Set `ml.enabled: false`, or allow egress and raise `probes.startup.failureThreshold` |
| `Permission denied` on `/synapse-data` | `fsGroup` does not match the volume | Leave `podSecurityContext.fsGroup` at the default |
| `SYNAPSE_LICENSE_KEY required` | Tier requires a license | Set `tier.licenseKey` or `tier.existingLicenseSecret` |
| Config parse error | Invalid `config.synapseToml`, or a hand-written `[cluster]` section | Remove `[cluster]`; the chart generates it |

### Killed during startup, no obvious error

The startup probe expired. Budget is
`probes.startup.failureThreshold × probes.startup.periodSeconds`, 600s by
default.

With the default `ml.enabled: false` a pod is ready in about 20 seconds, so this
almost always means index rebuild on a large graph. With `ml.enabled: true` the
first start also builds a ~4GB Python environment - 8 to 30 minutes - and a
probe that gives up partway produces a crash loop that looks like a broken
image. The chart refuses to render `ml.enabled` with a budget under 30 minutes
for exactly this reason.

```yaml
probes:
  startup:
    failureThreshold: 360   # 60 minutes at periodSeconds: 10
```

### Every cluster pod says "initialized as cluster-of-one leader"

The image was built without the `cluster` Cargo feature. A server without it
does not reject a multi-node configuration - it ignores `cluster.peers` and
bootstraps alone, and so does every other pod, leaving N independent databases
behind one Service that diverge from the first write.

The chart checks for this at container start-up and exits rather than let it
happen, so in practice you see the crash, not the divergence:

```
[bootstrap] FATAL: this image cannot run a multi-node cluster.
```

Check an image:

```bash
docker run --rm --entrypoint sh <image> -c \
  'grep -aq "cluster.listen must be set" /app/bin/synapse-server && echo supported || echo NOT supported'
```

Fix by rebuilding with `./scripts/build.sh --release --features cluster`, or set
`cluster.enabled=false` and run a single replica.

### Running but never Ready

```bash
kubectl -n synapse exec synapse-0 -- curl -s localhost:8080/health/ready | jq
```

```json
{ "status": "degraded",
  "checks": { "storage": "error", "catalog": "ok", "session_manager": "ok" } }
```

`storage: error` usually means the volume is full or not writable. Check:

```bash
kubectl -n synapse exec synapse-0 -- df -h /synapse-data
```

---

## OOM kills

Exit code 137, or `OOMKilled` in `kubectl describe pod`.

This is the failure mode worth understanding, because the cost is not a restart:
Synapse holds graph structure, vector indexes and caches resident, and losing
them means a full index rebuild on start-up.

```bash
# How close it is running
kubectl -n synapse exec synapse-0 -- curl -s localhost:8080/metrics | grep synapse_memory_rss_bytes
```

```yaml
resources:
  requests:
    memory: 24Gi    # close to the limit, not a fraction of it
  limits:
    memory: 32Gi
```

Relying on burst headroom does not work here: the memory is not optional, and
the node may not have it when a query needs it. If raising the limit is not an
option, cap the graph cache instead and accept slower cold queries:

```yaml
extraEnv:
  - name: SYNAPSE_GRAPH_CACHE_BYTES
    value: "8589934592"   # 8 GiB
```

---

## Cannot connect

```bash
kubectl -n synapse get svc
kubectl -n synapse get endpoints synapse     # empty means no pod is Ready
kubectl -n synapse port-forward svc/synapse 50051:50051 8080:8080
```

Empty endpoints is the common one, and it is a readiness problem, not a
networking problem - go back to the section above.

If a NetworkPolicy is on, confirm the client actually matches `allowedClients`:

```bash
kubectl -n synapse describe networkpolicy synapse
kubectl -n applications run nettest --rm -it --image=busybox -- \
  nc -zv synapse.synapse.svc.cluster.local 50051
```

If **everything** is blocked, including `helm test` and pods that clearly match
`allowedClients`, suspect the CNI rather than the rules. Some implementations
enforce the default-deny a policy implies without correctly matching
`podSelector` / `namespaceSelector` peers, so every rule fails to match and the
policy blocks all traffic. Confirm by deleting the policy:

```bash
kubectl -n synapse delete networkpolicy synapse   # then retry the connection
```

If that fixes it, the policy is not the problem - the CNI's NetworkPolicy
support is. Either switch to a CNI that implements it fully, or leave
`networkPolicy.enabled: false` and restrict access another way.

### Authentication fails with the password you set

First check what the pod was actually given:

```bash
kubectl -n synapse get secret synapse-credentials -o jsonpath='{.data.SYNAPSE_PASSWORD}' | base64 -d
```

If that matches what you configured, confirm the reset ran:

```bash
kubectl -n synapse logs synapse-0 | grep -i "admin password"
```

You should see `applying the configured admin password` from the bootstrap
script. If instead the built-in default still works, `auth.enforcePassword` is
off - the server seeds its admin account with a hardcoded password and ignores
what installation is given, so nothing else sets it:

```bash
helm upgrade synapse synapse/synapse -n synapse --reuse-values \
  --set auth.enforcePassword=true
```

The reverse case: a password you changed with `ALTER USER` stops working after a
restart. That is `auth.enforcePassword` doing its job - it re-applies the values
file on every start. Either update `auth.password`, or set
`auth.enforcePassword: false` and manage it in GQL.

See [security.md](security.md#how-the-password-actually-gets-set).

---

## Metrics not appearing in Prometheus

Check in this order - it is nearly always the second one.

```bash
# 1. Is Synapse serving them?
kubectl -n synapse exec synapse-0 -- curl -s localhost:8080/metrics | head

# 2. Does the ServiceMonitor's label match what Prometheus selects?
kubectl -n synapse get servicemonitor synapse -o jsonpath='{.metadata.labels}'
kubectl get prometheus -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceMonitorSelector}{"\n"}{end}'

# 3. Does the target show up?
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# then open /targets
```

```yaml
observability:
  serviceMonitor:
    labels:
      release: kube-prometheus-stack    # whatever step 2 printed
```

A kube-prometheus-stack installed with `serviceMonitorSelectorNilUsesHelmValues:
true` (its default) ignores ServiceMonitors without its release label even in a
watched namespace.

`/metrics` returning 503 with `# Metrics not initialized` means the registry has
not come up yet - the pod is still starting.

## Grafana dashboard missing

Three candidates:

1. `observability.grafanaDashboard.label` does not match
   `grafana.sidecar.dashboards.label`.
2. The sidecar watches one namespace and the ConfigMap is in another. Set
   `sidecar.dashboards.searchNamespace: ALL`.
3. The sidecar is not enabled.

```bash
kubectl -n synapse get cm synapse-dashboard -o jsonpath='{.metadata.labels}'
kubectl -n observability logs deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard | tail
```

---

## Cluster problems

### A pod will not join

```bash
kubectl -n synapse exec synapse-0 -- synapsectl cluster status
kubectl -n synapse exec synapse-1 -- cat /run/synapse/synapse.toml
kubectl -n synapse logs synapse-1 | grep -i raft
```

| Symptom | Cause |
|---|---|
| Peer DNS does not resolve | Pod 0 not Ready yet, or `headlessService.publishNotReadyAddresses` was turned off |
| TLS handshake failure | Certificate missing a pod FQDN, or missing the `client auth` usage |
| `cluster.listen must be set` | A hand-written `[cluster]` section is conflicting with the generated one |
| Two nodes claim to be seed | `SYNAPSE_INIT_CLUSTER` set outside the chart's ordinal-0 logic |

### No leader elected

Usually timing on a high-RTT network: followers time out on a heartbeat that is
merely slow, call an election, and the cluster spends its time changing leaders.

```yaml
cluster:
  raft:
    heartbeatIntervalMs: 500
    electionTimeoutMinMs: 2500
    electionTimeoutMaxMs: 5000
  rpcTimeoutMs: 10000
```

### Follower serving stale data

Expected, within limits - follower reads are not linearizable. Measure it:

```promql
max by (pod) (synapse_raft_apply_lag_seconds)
```

If it keeps growing, the follower cannot keep up: check its CPU and disk, and
whether the leader is producing writes faster than it can apply them.

### Quorum lost

Two of three down. The cluster stops accepting writes, which is correct -
committing without a majority is how split brain produces divergent data.

Restore nodes until a majority is back. **Do not delete PVCs to "reset" the
cluster**: that discards committed writes held only by those replicas.

---

## Upgrade problems

### `spec.volumeClaimTemplates is forbidden`

StatefulSet volume claim templates are immutable. `persistence.data.size` and
`storageClass` cannot be changed by upgrade - expand the PVCs directly. See
[storage.md](storage.md#growing-a-volume).

### Rollback did not restore the data

It does not, and cannot. `helm rollback` reverts manifests; writes committed
under the newer version are still in the volume. Treat rollback as a fix for a
bad configuration, not a bad migration. Restore from a backup for the latter.

---

## Getting diagnostics out

```bash
kubectl -n synapse logs synapse-0 --tail=1000 > synapse.log
kubectl -n synapse describe pod synapse-0 > pod.txt
kubectl -n synapse exec synapse-0 -- curl -s localhost:8080/metrics > metrics.txt
helm get values synapse -n synapse > values.yaml    # redact secrets before sharing
kubectl -n synapse exec synapse-0 -- synapse version
```

For a deeper look, temporarily enable the debug endpoints - and turn them back
off afterwards, since they are unauthenticated:

```bash
helm upgrade synapse synapse/synapse -n synapse --reuse-values \
  --set server.http.debugEndpoints=true

kubectl -n synapse exec synapse-0 -- curl -s localhost:8080/debug/queries | jq
kubectl -n synapse exec synapse-0 -- curl -s localhost:8080/debug/memory | jq
kubectl -n synapse exec synapse-0 -- curl -s localhost:8080/debug/indexes | jq
```
