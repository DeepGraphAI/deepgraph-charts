# Clustering

Synapse replicates through Raft. One node is the leader and accepts writes; a
write is committed once a majority of voters has it durably in their log.
Followers apply the same log and can serve reads, which may be slightly stale.

This is worth stating plainly because it sets the shape of everything below:

**Replication is by log, not by volume.** Each pod has its own PVC holding its
own copy. There is no shared disk, and `replicaCount: 3` with
`cluster.enabled: false` is not a cluster - it is three unrelated databases
behind one Service, where a client gets different data depending on which pod it
lands on. The chart prints a warning when it sees that combination.

## Sizing

| Voters | Tolerates | Notes |
|---|---|---|
| 1 | nothing | Restart window is the outage |
| 3 | 1 failure | The usual choice |
| 5 | 2 failures | Every write waits for 3 acknowledgements |

Use an odd number. Four voters tolerate the same single failure as three while
requiring one more node to agree on every write - strictly worse on both axes.

## Prerequisites

1. **Three or more schedulable nodes.** With `podAntiAffinity.type: hard` the
   pods refuse to co-locate, and a two-node cluster leaves the third pod
   `Pending` forever.
2. **Per-pod storage.** Any StorageClass that provisions `ReadWriteOnce`.
3. **mTLS material.** The Raft port carries replicated writes. Without TLS they
   cross the network in the clear, and the server logs a warning saying so on
   every start.

### Issuing the cluster certificate

With cert-manager, one certificate covers every pod because the peers are
addressed by their stable pod FQDNs:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: synapse-cluster-tls
  namespace: synapse
spec:
  secretName: synapse-cluster-tls
  duration: 8760h
  renewBefore: 720h
  isCA: false
  usages:
    - server auth
    - client auth   # Raft peers are both, so both usages are required
  dnsNames:
    - synapse-0.synapse-headless.synapse.svc.cluster.local
    - synapse-1.synapse-headless.synapse.svc.cluster.local
    - synapse-2.synapse-headless.synapse.svc.cluster.local
    - synapse-headless.synapse.svc.cluster.local
  issuerRef:
    name: synapse-ca-issuer
    kind: Issuer
```

The chart expects `ca.crt`, `tls.crt` and `tls.key` in that Secret, which is the
layout cert-manager produces. Scaling past the listed names needs the
certificate reissued with the new pod FQDNs included.

## Install

```bash
helm install synapse synapse/synapse -n synapse -f examples/03-ha-cluster.yaml
```

What the chart does that a single-node install does not:

- Adds a `bootstrap.sh` ConfigMap and runs it as the container command. It
  derives the pod's ordinal from its hostname, writes a per-pod `[cluster]`
  section, and execs the normal entrypoint.
- Sets `podManagementPolicy: OrderedReady`, so pod 0 is ready before pod 1
  starts.
- Exports `SYNAPSE_INIT_CLUSTER=1` on ordinal 0 only. That node seeds the
  initial membership; the others learn it from the leader's first
  AppendEntries. The call is idempotent, so restarting pod 0 later is a no-op.
- Opens the Raft and admin ports on the headless Service, and restricts them to
  Synapse pods in the NetworkPolicy.

### Why the bootstrap script exists

A ConfigMap is identical across pods, but every pod needs a different
`cluster.node_id` and a different bind address. The server reads one
`synapse.toml`. So the per-pod part is generated at start-up and appended to the
mounted base file.

One detail worth knowing, because it explains something that otherwise looks
inconsistent: `cluster.listen` is set to the **pod IP**, while the peer list
names the same node by its **pod FQDN**. The bind address has to parse as
`IP:port`, which a DNS name does not. The peer entry then re-states the node
with its stable name, and that is what lands in Raft membership - a pod IP would
go stale the first time the pod is rescheduled.

Inspect what a pod actually got:

```bash
kubectl -n synapse exec synapse-0 -- cat /run/synapse/synapse.toml
```

## Operating

`synapsectl` talks to the admin port.

```bash
# Membership, leader, applied and committed indexes, per-member match index
kubectl -n synapse exec -it synapse-0 -- synapsectl cluster status

# Force a snapshot
kubectl -n synapse exec -it synapse-0 -- synapsectl cluster snapshot

# Move leadership off a node before maintenance
kubectl -n synapse exec -it synapse-0 -- synapsectl cluster transfer-leadership

# Stop routing work to a node ahead of removing it
kubectl -n synapse exec -it synapse-0 -- synapsectl cluster drain
```

A dash in the `Matched` column usually means the request reached a follower.
Only the leader has authoritative replication progress for every member.

### Scaling up

```bash
helm upgrade synapse synapse/synapse -n synapse \
  -f examples/03-ha-cluster.yaml --set replicaCount=5
```

This regenerates the bootstrap ConfigMap with the larger peer list and starts
the new pods. Then:

1. Reissue the cluster certificate with the new pod FQDNs.
2. Add each new node as a learner, let it catch up, then promote it:

   ```bash
   kubectl -n synapse exec -it synapse-0 -- synapsectl cluster add-learner --node-id 4
   kubectl -n synapse exec -it synapse-0 -- synapsectl cluster status   # wait for its matched index
   kubectl -n synapse exec -it synapse-0 -- synapsectl cluster add-voter --node-id 4
   ```

Promoting before the learner has caught up makes it a voter that cannot vote
usefully, which narrows your real fault tolerance without changing the numbers
the status command reports.

### Scaling down

Remove from membership first, then scale the StatefulSet. Dropping a pod that is
still a voter removes a vote from quorum without telling the cluster.

```bash
kubectl -n synapse exec -it synapse-0 -- synapsectl cluster drain --node-id 5
kubectl -n synapse exec -it synapse-0 -- synapsectl cluster remove-node --node-id 5
helm upgrade synapse synapse/synapse -n synapse --set replicaCount=4 ...
```

`persistence.data.retentionPolicy.whenScaled: Retain` keeps the departed
replica's PVC, so re-adding it later resumes from its existing log instead of
transferring a full snapshot.

### Rolling upgrades

A `RollingUpdate` replaces one pod at a time, highest ordinal first, waiting for
readiness between each. With three voters that keeps two up throughout, so the
cluster holds quorum and stays writable. `podDisruptionBudget.maxUnavailable: 1`
stops a node drain from taking a second pod while one is already down.

## Timing for high-RTT deployments

Defaults are tuned for a LAN. Across availability zones or regions, raise all
three together and keep `heartbeat < electionMin < electionMax`:

```yaml
cluster:
  raft:
    heartbeatIntervalMs: 500
    electionTimeoutMinMs: 2500
    electionTimeoutMaxMs: 5000
  rpcTimeoutMs: 10000
```

Leaving the LAN defaults on a cross-region cluster produces repeated spurious
elections: followers time out waiting for a heartbeat that is merely slow, call
an election, and the cluster spends its time changing leaders instead of
committing writes.

The server validates these on start-up and refuses to boot on an invalid
combination, rather than panicking later.

## Reads, writes and staleness

Writes always go to the leader. A client that connects to a follower has its
write forwarded or rejected depending on configuration; it never commits
locally.

Follower reads are not linearizable. A follower serves from its own applied
state, which may trail the leader. `synapse_raft_apply_lag_seconds` measures
exactly that, in seconds, and reads 0 on the leader. Alert on it - the chart's
`raftApplyLag` rule does, at 30s by default - because a lagging follower does
not fail, it quietly answers with old data.

Before relying on a follower read, check its matched index in
`synapsectl cluster status`.

## Recovery

**One node lost.** The cluster keeps working. Kubernetes reschedules the pod, it
reopens its PVC and replays the log tail from the leader. Nothing to do.

**PVC lost with the node.** Delete the PVC so a fresh one is provisioned, delete
the pod, and the new replica catches up by snapshot transfer. On a large graph
that is slow - `cluster.snapshotLogsThreshold` trades more frequent snapshot
work on the leader for a shorter tail to replay.

**Quorum lost** (two of three down). The cluster stops accepting writes, by
design: committing without a majority is how split brain produces divergent
data. Restore nodes until a majority is back. Do not delete PVCs to "reset" -
that discards committed writes that only those replicas hold.

**Leader's pod IP changed after a full-cluster restart.** Peer addresses in
membership are pod FQDNs, which survive rescheduling, so this is handled. If
membership somehow does hold a stale address, repair it with
`synapsectl cluster remove-node` followed by `add-node` carrying the correct
address.

## Monitoring

Cluster-specific alerts ship in the chart's PrometheusRule and are only rendered
when `cluster.enabled` is true:

| Alert | Fires on | Meaning |
|---|---|---|
| `SynapseRaftApplyLag` | lag > 30s for 5m | Follower reads are stale |
| `SynapseRaftApplyErrors` | any apply error for 5m | Write path failing on a replica |

Worth charting alongside them: `synapse_raft_apply_latency_seconds`,
`synapse_raft_snapshot_install_total` and
`synapse_raft_apply_writes_total`. All are on the bundled dashboard's Cluster
row.
