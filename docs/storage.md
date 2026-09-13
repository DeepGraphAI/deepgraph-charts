# Storage

Synapse stores everything under one directory (`dataDir`, default
`/synapse-data`), backed by a PVC from the StatefulSet's `volumeClaimTemplates`.
Each pod gets its own volume; there is no shared disk, even in cluster mode.

## What lives there

| Contents | Grows with |
|---|---|
| RocksDB column families - nodes, edges, properties | Graph size |
| Vector indexes (HNSW / NSW) | Embedding count and dimension |
| Text indexes | Indexed text volume |
| Catalog - schemas, graphs, users, roles | Number of objects, slowly |
| Raft log and snapshots | Write rate, bounded by snapshot settings |

## Choosing a StorageClass

Graph traversal is random-read heavy: a multi-hop query is a chain of small
dependent reads, and each hop's latency adds rather than amortizes. Vector search
over an index larger than RAM has the same shape.

That makes IOPS and latency matter far more than throughput.

| Class | Suitable | Notes |
|---|---|---|
| Local NVMe | Best | Lowest latency. Node-local, so a node loss means a replica rebuild |
| Network SSD (gp3, pd-ssd, Premium SSD) | Yes | The usual choice. Provision IOPS explicitly on gp3 |
| Network HDD (sc1, st1, standard) | No | A 5ms hop becomes 50ms and multi-hop queries compound it |
| NFS / EFS | No | Latency and file-locking semantics both work against RocksDB |

```yaml
persistence:
  data:
    storageClass: gp3
    size: 500Gi
```

On EBS gp3, baseline IOPS scale with size only up to a point; provision them on
the StorageClass if the graph is busy:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: synapse-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "16000"
  throughput: "1000"
allowVolumeExpansion: true   # set this now; it cannot be added retroactively
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
```

`allowVolumeExpansion: true` is worth setting even if you do not need it yet -
it cannot be added to an existing class in a way that helps volumes already
provisioned from it.

## Sizing

Start from the raw data and multiply. RocksDB overhead, indexes, compaction
headroom and the Raft log all sit on top.

| Input | Rough planning figure |
|---|---|
| Nodes and edges with properties | 3-5x the raw size, after RocksDB overhead |
| Vector index | `vectors x dimensions x 4 bytes`, plus ~50% for HNSW graph links |
| Text index | ~30-50% of the indexed text |
| Compaction headroom | Leave 30% of the volume free |
| Raft log and snapshots | Bounded by `cluster.snapshotLogsThreshold` |

A worked example - 50M nodes, 200M edges, 10M 768-dimension vectors:

```
graph data      ~200 GB   (after overhead)
vector index     ~46 GB   (10M x 768 x 4 = 30GB, plus links)
text index       ~20 GB
free headroom   ~110 GB   (30%)
                -------
                ~380 GB   ->  provision 500Gi
```

Over-provisioning is much cheaper than the alternative. A full volume does not
degrade gracefully: RocksDB compaction stalls, writes block, and recovery means
expanding the volume under a database that is already unhappy.

## Memory matters more than disk

Worth stating here because it is the most common sizing mistake: Synapse keeps
graph structure, vector indexes and caches resident in memory. An OOM kill is
not a restart - it costs a full vector and text index rebuild on start-up, which
on a large graph is minutes of unavailability.

Set the memory request close to the limit rather than relying on burst headroom
that may not be there when a query needs it:

```yaml
resources:
  requests:
    memory: 24Gi
  limits:
    memory: 32Gi
```

Watch `synapse_memory_rss_bytes` against the limit; the bundled dashboard has
that panel and the `SynapseHighMemoryUsage` alert fires at 90%.

## Growing a volume

A StatefulSet's `volumeClaimTemplates` are immutable, so `helm upgrade` cannot
change `persistence.data.size`. Attempting it produces a rejected update, not a
resize.

Expand the PVCs directly, then set the value so future replicas match:

```bash
# One per pod
kubectl -n synapse patch pvc data-synapse-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"1Ti"}}}}'

kubectl -n synapse get pvc -w    # wait for FileSystemResizePending to clear
```

Most CSI drivers expand the filesystem online. Some need a pod restart to pick
up the new size; check `kubectl describe pvc` for a `FileSystemResizePending`
condition that does not clear.

Then, so a scale-up provisions correctly sized volumes:

```yaml
persistence:
  data:
    size: 1Ti
```

## Retention

```yaml
persistence:
  data:
    retentionPolicy:
      whenDeleted: Retain
      whenScaled: Retain
```

Both default to `Retain`.

`whenScaled: Retain` matters in cluster mode: a scaled-down replica keeps its
Raft log, so re-adding it later resumes from where it left off instead of
transferring a full snapshot.

`whenDeleted: Retain` means `helm uninstall` leaves the data behind, and
reinstalling with the same release name in the same namespace picks it back up.
To actually delete it:

```bash
kubectl -n synapse delete pvc -l app.kubernetes.io/name=synapse
```

Requires Kubernetes 1.27+ for the field to be honoured. On older clusters it is
ignored and PVCs are kept regardless, which is the same outcome as the default.

## Backups

### Volume snapshots

The straightforward approach, if your CSI driver supports it:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: synapse-data-0-20260913
  namespace: synapse
spec:
  volumeSnapshotClassName: csi-snapshotter
  source:
    persistentVolumeClaimName: data-synapse-0
```

A snapshot of a running database is crash-consistent, not
application-consistent: it captures whatever RocksDB had written at that
instant. RocksDB recovers from that on start-up, the same way it recovers from a
power loss, so it is usable - but a quiesced snapshot is better if you can
arrange one.

In cluster mode, snapshot the leader. Followers may trail it.

### Logical export

Portable across storage backends and across versions, which a volume snapshot is
not:

```bash
kubectl -n synapse exec -it synapse-0 -- \
  synapse gql --grpc --address 127.0.0.1 --port 50051
```

```gql
CALL gql.create_backup('/synapse-data/backups/20260913');
```

Write backups to a volume that is not the data volume, or copy them off the pod
afterwards - a backup that shares a disk with the thing it backs up does not
survive the failure it exists for.

### Scheduled

With Velero:

```bash
velero schedule create synapse-daily \
  --schedule "0 2 * * *" \
  --include-namespaces synapse \
  --ttl 720h
```

Whatever you use, restore it somewhere at least once before you need it. An
untested backup is a hypothesis.

## Ephemeral storage

```yaml
persistence:
  data:
    enabled: false
```

Uses an `emptyDir`. Every pod restart starts from an empty graph. Correct for
CI and for a demo cluster; wrong for anything else, and the chart prints a
warning. `cluster.enabled` refuses to combine with it, because a Raft log that
does not survive a restart is not a Raft log.
