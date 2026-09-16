# Configuration reference

Every value the chart accepts, grouped by what it affects. Defaults are in
[charts/synapse/values.yaml](../charts/synapse/values.yaml), which carries the
same information inline.

## Image

| Value | Default | Description |
|---|---|---|
| `image.repository` | `""` | **Required** - registry path of your build |
| `image.tag` | `""` | Empty means the chart's `appVersion` |
| `image.digest` | `""` | Pin by digest. Overrides `tag` |
| `image.pullPolicy` | `IfNotPresent` | |
| `image.pullSecrets` | `[]` | Names of pull Secrets in this namespace |

Pin by digest in regulated or air-gapped environments: a tag can be re-pushed,
a digest cannot.

## Identity and topology

| Value | Default | Description |
|---|---|---|
| `nameOverride` | `""` | Replaces the chart name in generated names |
| `fullnameOverride` | `""` | Replaces the full generated name |
| `clusterDomain` | `cluster.local` | Used to build pod FQDNs for Raft peering |
| `replicaCount` | `1` | Pods. See the warning below |
| `commonLabels` | `{}` | Merged into every object |
| `commonAnnotations` | `{}` | Merged into every object |

`replicaCount` above 1 without `cluster.enabled` produces N independent
databases behind one Service. The chart warns at install time. See
[clustering.md](clustering.md).

## Authentication

| Value | Default | Description |
|---|---|---|
| `auth.username` | `admin` | Bootstrap admin user |
| `auth.password` | `""` | **Required** unless `existingSecret` is set |
| `auth.existingSecret` | `""` | Read credentials from this Secret instead |
| `auth.secretKeys.username` | `SYNAPSE_USER` | Key within `existingSecret` |
| `auth.secretKeys.password` | `SYNAPSE_PASSWORD` | Key within `existingSecret` |
| `auth.enforcePassword` | `true` | Apply `auth.password` at every start |

A fresh install always applies `auth.password`. `auth.enforcePassword` governs
what happens on a volume that already holds an admin account: on, the configured
password is re-applied at every start, so changing `auth.password` and upgrading
rotates it; off, the account keeps whatever password it has, which is what you
want when managing it through GQL.

Both paths run in a process that exits before the server opens the database, so
the server reads the new credential when it boots rather than serving a cached
one. Requires an image carrying the admin-password fix; the chart refuses to
start without it. Full detail in
[security.md](security.md#how-the-password-gets-set).

`auth.username` is only used for client connections; the admin account name
itself is fixed by the server.

## Tier and licensing

| Value | Default | Description |
|---|---|---|
| `tier.level` | `enterprise` | `enterprise`, `professional` or `graphlite` |
| `tier.licenseKey` | `""` | Injected as `SYNAPSE_LICENSE_KEY` |
| `tier.existingLicenseSecret` | `""` | Secret holding a `SYNAPSE_LICENSE_KEY` key |

The tier gates features: vector search, model management and the AI runtime are
not available at every level. A query that uses a gated feature fails with an
explicit tier error rather than degrading.

## Listeners

| Value | Default | Description |
|---|---|---|
| `server.grpc.port` | `50051` | Primary client API. Cannot be disabled |
| `server.http.enabled` | `true` | UI, REST, `/health`, `/metrics` |
| `server.http.port` | `8080` | |
| `server.http.timeoutSeconds` | `30` | Standard route timeout |
| `server.http.agentTimeoutSeconds` | `300` | Conversational-agent route timeout |
| `server.http.maxConnections` | `1000` | |
| `server.http.debugEndpoints` | `false` | Exposes `/debug/*` |
| `server.http.corsOrigins` | `[]` | Cross-origin callers allowed |
| `server.bolt.enabled` | `false` | Neo4j-compatible driver protocol |
| `server.bolt.port` | `7687` | |
| `server.bolt.languages` | `gql,opencypher` | Accepted dialects |
| `server.bolt.maxConnections` | `512` | |
| `server.bolt.idleTimeoutSeconds` | `600` | |
| `server.bolt.advertisedAddress` | `""` | What drivers should reconnect to |

Turning off `server.http.enabled` disables probes that mean anything (they fall
back to a TCP check on the gRPC port, which only proves the socket is bound),
the ServiceMonitor, the Ingress and the UI. The chart refuses to render if you
enable those alongside it.

`server.http.debugEndpoints` publishes memory maps, in-flight queries and index
internals with no authentication of its own. Leave it off in production.

## Runtime

| Value | Default | Description |
|---|---|---|
| `server.logLevel` | `info` | `trace`/`debug`/`info`/`warn`/`error` |
| `server.logFormat` | `json` | `json` or `text` |
| `server.maxInboundMb` | `64` | gRPC request size cap |
| `server.maxOutboundMb` | `2047` | gRPC response size cap (protocol max) |
| `server.maxConcurrentStreams` | `1000` | |
| `server.stagingDir` | `/tmp/synapse/staging` | Batch payload staging |
| `server.extraArgs` | `[]` | Appended to the server command line |
| `dataDir` | `/synapse-data` | Data directory, and the PVC mount point |

`server.logFormat: json` is what makes logs queryable in Loki without a parser
pipeline. Use `text` only when a human is reading the terminal.

## AI and models

| Value | Default | Description |
|---|---|---|
| `ml.enabled` | `false` | Build and use the Python/AI runtime |
| `ml.models` | `none` | `none`, `all`, or a subset. Ignored when disabled |
| `ml.persistence.mlEnv.enabled` | `true` | Persist the Python environment |
| `ml.persistence.mlEnv.size` | `10Gi` | Measured at ~4GB |
| `ml.persistence.models.enabled` | `false` | Persist the model cache |
| `ml.persistence.models.size` | `30Gi` | |

The image's entrypoint builds a ~4GB Python environment on first start whether
or not you use an AI feature, because the server binary links against libpython.
That takes 8-30 minutes and needs egress to a package index.

The server does not require it. A missing environment is a start-up warning, not
an error: graph traversal, vector search over embeddings you supply, full-text
search and the whole GQL surface work without it. Only the in-database AI
features - register or load a model, compute embeddings, extraction - need it.

So `ml.enabled` defaults to `false` and the chart starts the server directly,
which takes about 20 seconds. Turn it on when you want Synapse computing
embeddings itself; keep `ml.persistence.mlEnv` on so restarts do not repeat the
build, and raise `probes.startup.failureThreshold` to at least 240 (the chart
refuses to render otherwise).

## Server configuration file

| Value | Default | Description |
|---|---|---|
| `config.synapseToml` | `""` | Inline `synapse.toml`, templated |
| `config.existingConfigMap` | `""` | ConfigMap holding a `synapse.toml` key |
| `externalAuth.enabled` | `false` | Mount an external-auth TOML |
| `externalAuth.config` | `""` | Inline TOML |
| `externalAuth.existingSecret` | `""` | Secret holding `external-auth.toml` |

When `config.synapseToml` is empty the chart generates a minimal file carrying
only the tier, and every other setting falls back to the server's compiled-in
defaults. That is the right starting point; reach for a full file only when you
need to tune storage, cache or text-search internals.

Do not write a `[cluster]` section yourself. In cluster mode the chart appends a
per-pod one, and a duplicate section is a parse error.

`SYNAPSE_DATA_DIR` takes precedence over any `data-dir` in the file, and the
chart always sets it from `dataDir`, so the mount point and the server can never
disagree.

## Clustering

| Value | Default | Description |
|---|---|---|
| `cluster.enabled` | `false` | Turn on Raft replication. Needs a `cluster`-feature image |
| `cluster.raftPort` | `5701` | Raft RPC |
| `cluster.admin.enabled` | `true` | Admin gRPC for `synapsectl` |
| `cluster.admin.port` | `5702` | |
| `cluster.rpcTimeoutMs` | `5000` | Per-RPC client timeout |
| `cluster.snapshotLogsThreshold` | `""` | Entries between snapshots |
| `cluster.maxInSnapshotLogToKeep` | `""` | Snapshotted entries kept on disk |
| `cluster.raft.heartbeatIntervalMs` | `""` | |
| `cluster.raft.electionTimeoutMinMs` | `""` | Must exceed the heartbeat |
| `cluster.raft.electionTimeoutMaxMs` | `""` | Must exceed the min |
| `cluster.raft.maxPayloadEntries` | `""` | Entries per AppendEntries |
| `cluster.tls.enabled` | `false` | mTLS between Raft peers |
| `cluster.tls.existingSecret` | `""` | Secret with `ca.crt`, `tls.crt`, `tls.key` |

Multi-node Raft is a non-default build feature, and a server without it ignores
the peer list and starts as a single node rather than failing - so every pod
becomes its own database. The chart checks the binary at start-up and refuses to
run instead. See [clustering.md](clustering.md#prerequisites).

## Services and exposure

| Value | Default | Description |
|---|---|---|
| `service.type` | `ClusterIP` | |
| `service.annotations` | `{}` | |
| `service.sessionAffinity` | `None` | `ClientIP` pins a client to one pod |
| `service.loadBalancerIP` | `""` | |
| `service.loadBalancerSourceRanges` | `[]` | |
| `service.externalTrafficPolicy` | `""` | |
| `service.nodePorts.{grpc,http,bolt}` | `""` | NodePort/LoadBalancer only |
| `headlessService.annotations` | `{}` | |
| `headlessService.publishNotReadyAddresses` | `true` | Required for Raft peering |
| `ingress.enabled` | `false` | HTTP listener only |
| `ingress.className` | `""` | |
| `ingress.annotations` | `{}` | |
| `ingress.hosts` | see values | |
| `ingress.tls` | `[]` | |

An Ingress carries HTTP, so it publishes port 8080 only. To expose gRPC or BOLT
externally, use a service mesh gateway or a Gateway API implementation that
speaks HTTP/2 or raw TCP.

## Storage

| Value | Default | Description |
|---|---|---|
| `persistence.data.enabled` | `true` | `false` uses an emptyDir |
| `persistence.data.size` | `50Gi` | |
| `persistence.data.storageClass` | `""` | Empty means the cluster default |
| `persistence.data.accessModes` | `[ReadWriteOnce]` | |
| `persistence.data.annotations` | `{}` | |
| `persistence.data.retentionPolicy.whenDeleted` | `Retain` | |
| `persistence.data.retentionPolicy.whenScaled` | `Retain` | |

`volumeClaimTemplates` are immutable after creation, so size and StorageClass
cannot be changed by `helm upgrade`. See
[storage.md](storage.md#growing-a-volume).

## Probes

| Value | Default | Description |
|---|---|---|
| `probes.startup.enabled` | `true` | |
| `probes.startup.periodSeconds` | `10` | |
| `probes.startup.failureThreshold` | `60` | 10 minutes of budget. At least 240 when `ml.enabled` |
| `probes.liveness.*` | see values | |
| `probes.readiness.*` | see values | |

The startup probe is what gives a slow start room without loosening the liveness
threshold afterwards. Raise `failureThreshold` when the graph is large enough
that index rebuild takes a while, or when `ml.enabled` is on. Startup budget in
seconds is `failureThreshold × periodSeconds`.

Readiness hits `/health/ready`, which reports 503 until storage, catalog and the
session manager are all up - so a pod is kept out of the Service until it can
actually answer.

## Resources and scheduling

| Value | Default | Description |
|---|---|---|
| `resources` | 500m/2Gi to 4/8Gi | |
| `nodeSelector`, `tolerations`, `affinity` | `{}`/`[]`/`{}` | Standard |
| `podAntiAffinity.enabled` | `true` | Ignored when `affinity` is set |
| `podAntiAffinity.type` | `soft` | `hard` refuses to co-locate pods |
| `podAntiAffinity.topologyKey` | `kubernetes.io/hostname` | |
| `topologySpreadConstraints` | `[]` | |
| `priorityClassName` | `""` | |
| `terminationGracePeriodSeconds` | `120` | RocksDB flush and log settle |
| `updateStrategy.type` | `RollingUpdate` | |
| `podDisruptionBudget.enabled` | `false` | |
| `podDisruptionBudget.maxUnavailable` | `1` | |

Memory is the resource that matters. Synapse holds graph structure, vector
indexes and caches resident, and an OOM kill costs a full index rebuild on
restart - so set the request close to the limit rather than relying on burst
headroom that may not be there.

For a cluster, use `podAntiAffinity.type: hard`: two voters on one node means a
single node failure costs quorum.

## Security

| Value | Default | Description |
|---|---|---|
| `serviceAccount.create` | `true` | |
| `serviceAccount.name` | `""` | |
| `serviceAccount.annotations` | `{}` | For IRSA, Workload Identity |
| `serviceAccount.automountServiceAccountToken` | `false` | Synapse calls no Kubernetes API |
| `podSecurityContext` | see values | |
| `containerSecurityContext` | see values | |
| `networkPolicy.enabled` | `false` | |
| `networkPolicy.allowedClients` | `[]` | Empty means the whole namespace |
| `networkPolicy.allowExternalEgress` | `true` | |

`containerSecurityContext.readOnlyRootFilesystem` is `false` because first-run
setup writes into `/app`. It can be turned on with `ml.enabled: false` and an
image that needs no first-run work.

See [security.md](security.md).

## Observability

| Value | Default | Description |
|---|---|---|
| `observability.podAnnotations.enabled` | `false` | Annotation-based scraping |
| `observability.serviceMonitor.enabled` | `false` | Prometheus Operator |
| `observability.serviceMonitor.labels` | `{}` | Must match your Prometheus selector |
| `observability.serviceMonitor.interval` | `30s` | |
| `observability.serviceMonitor.metricRelabelings` | `[]` | |
| `observability.prometheusRule.enabled` | `false` | |
| `observability.prometheusRule.rules.*` | see values | Per-alert thresholds |
| `observability.prometheusRule.extraRules` | `[]` | Appended verbatim |
| `observability.grafanaDashboard.enabled` | `false` | |
| `observability.grafanaDashboard.label` | `grafana_dashboard` | Sidecar's watch label |
| `observability.otel.enabled` | `false` | OTLP trace export |
| `observability.otel.endpoint` | collector | |
| `observability.otel.sampleRate` | `0.1` | |

See [observability.md](observability.md).

## Service mesh

| Value | Default | Description |
|---|---|---|
| `serviceMesh.istio.enabled` | `false` | |
| `serviceMesh.istio.injectSidecar` | `true` | Prefer labelling the namespace |
| `serviceMesh.istio.peerAuthentication.mode` | `STRICT` | |
| `serviceMesh.istio.gateway.*` | see values | |
| `serviceMesh.istio.virtualService.*` | see values | |
| `serviceMesh.istio.destinationRule.*` | see values | |

See [service-mesh.md](service-mesh.md).

## Escape hatches

| Value | Default | Description |
|---|---|---|
| `extraEnv` | `[]` | Standard container env entries |
| `extraEnvFrom` | `[]` | Extra ConfigMap or Secret sources |
| `extraVolumes` / `extraVolumeMounts` | `[]` | |
| `extraInitContainers` / `extraContainers` | `[]` | |
| `podAnnotations` / `podLabels` | `{}` | |
| `extraManifests` | `[]` | Full manifests, templated |

`extraEnv` is how you reach any server setting the chart does not model. The
server reads a large set of `SYNAPSE_*` variables; a few that come up:

```yaml
extraEnv:
  # Cap the graph cache explicitly rather than letting it grow to the limit.
  - name: SYNAPSE_GRAPH_CACHE_BYTES
    value: "4294967296"
  # Longer window for REST-driven ingestion.
  - name: SYNAPSE_HTTP_TIMEOUT_SECS
    value: "600"
```
