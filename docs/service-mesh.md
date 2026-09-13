# Service mesh

The chart can render Istio's `PeerAuthentication`, `Gateway`, `VirtualService`
and `DestinationRule` alongside the database.

What a mesh actually buys here: the gRPC and BOLT ports carry credentials and
query text, and neither protocol encrypts itself in the chart's default
configuration. Sidecar-terminated mTLS protects the wire without configuring TLS
inside the database, and gives you identity-based policy on top.

## Setup

```bash
istioctl install --set profile=default
kubectl label namespace synapse istio-injection=enabled

helm install synapse synapse/synapse -n synapse -f examples/05-service-mesh.yaml
```

Labelling the namespace is preferable to the pod annotation. Use
`serviceMesh.istio.injectSidecar` only when the namespace is shared and only
Synapse should be meshed.

## mTLS

```yaml
serviceMesh:
  istio:
    enabled: true
    peerAuthentication:
      enabled: true
      mode: STRICT
```

`STRICT` makes the sidecar refuse any plaintext connection to these pods.

Do not start there if clients are still being migrated into the mesh - going
straight to `STRICT` drops every unmeshed client at once. Start `PERMISSIVE`,
confirm from Istio telemetry that nothing is still arriving in plaintext, then
switch:

```promql
sum by (source_workload) (
  rate(istio_requests_total{destination_service=~"synapse.*", connection_security_policy!="mutual_tls"}[5m])
)
```

Zero for a full traffic cycle means `STRICT` is safe.

## gRPC through the mesh

Two settings matter, and both are in the example:

```yaml
destinationRule:
  connectionPool:
    http:
      h2UpgradePolicy: UPGRADE        # gRPC is HTTP/2
      maxRequestsPerConnection: 0     # 0 = unlimited
```

`h2UpgradePolicy: UPGRADE` is required, or the proxy handles the connection as
HTTP/1.1 and streaming responses are buffered.

`maxRequestsPerConnection: 0` matters more than it looks. A non-zero value makes
Envoy recycle the connection after N requests, which severs long-running queries
and streaming results mid-flight. Leave it unlimited for a database.

The Gateway declares gRPC as its own server block rather than folding it into
the HTTP one, for the same HTTP/2 reason:

```yaml
gateway:
  exposeGrpc: true
```

## BOLT through the mesh

BOLT is routed as TCP - Envoy cannot parse it, so there is no L7 policy on that
port, only mTLS and connection-level routing.

Drivers reconnect to whatever address the server advertises, and the pod's own
address is not reachable from outside. Set it explicitly:

```yaml
server:
  bolt:
    enabled: true
    advertisedAddress: "synapse.example.com:7687"
```

Without it, a driver connects through the gateway, receives the pod address, and
fails its next connection with an error that points nowhere useful.

## Timeouts and retries

```yaml
virtualService:
  timeout: 120s
  retries:
    attempts: 2
    perTryTimeout: 60s
```

The default 15s Istio timeout is too short for ingestion calls.

On retries: these apply to connection-level failures - `gateway-error`,
`connect-failure`, `refused-stream`. A query that reached the server and failed
there is not retried by the proxy, and that is deliberate. Retrying a write that
may have partially applied is the kind of thing a proxy should never decide on
its own; write retry belongs in the client, which knows the transaction's
semantics.

## Outlier detection and cluster mode

```yaml
destinationRule:
  outlierDetection:
    consecutive5xxErrors: 5
    interval: 30s
    baseEjectionTime: 30s
    maxEjectionPercent: 50
```

The chart applies this to single-node deployments and **omits it in cluster
mode**, on purpose.

In a Raft cluster the leader is the only pod that accepts writes. Ejecting it on
a transient 5xx does not route around a bad replica - it takes the write path
down until the ejection expires or a new leader is elected. Since Envoy has no
idea which pod is the leader, it cannot make that call safely.

If you know follower reads are acceptable for your workload and want ejection
anyway, set `serviceMesh.istio.destinationRule.outlierDetection` explicitly and
be aware of what it does to writes.

## Layering with NetworkPolicy

Use both. They answer different questions:

- **mTLS**: is this caller who they claim to be, and is the traffic encrypted?
- **NetworkPolicy**: is this caller allowed to open a connection at all?

A mesh with a compromised sidecar still has a NetworkPolicy in front of it. When
the mesh is on, allow the `istio-system` namespace through:

```yaml
networkPolicy:
  enabled: true
  allowedClients:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: applications
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: istio-system
```

## Other meshes

The chart renders Istio resources specifically. For Linkerd, Cilium or Consul,
leave `serviceMesh.istio.enabled` off and use the generic hooks:

```yaml
podAnnotations:
  linkerd.io/inject: enabled

extraManifests:
  - apiVersion: policy.linkerd.io/v1beta1
    kind: Server
    metadata:
      name: synapse-grpc
    spec:
      podSelector:
        matchLabels:
          app.kubernetes.io/name: synapse
      port: grpc
      proxyProtocol: gRPC
```

`extraManifests` entries are templated, so `{{ }}` referencing chart values
works inside them.

## Troubleshooting

**gRPC connections hang or stream nothing.** `h2UpgradePolicy` is not `UPGRADE`.

**Long queries are cut off mid-result.** `maxRequestsPerConnection` is non-zero,
or the VirtualService timeout is shorter than the query.

**Clients fail immediately after switching to STRICT.** They are not in the
mesh. Check the telemetry query above, go back to `PERMISSIVE`, and mesh them
first.

**Raft peering breaks when the mesh is enabled.** Peers address each other by
pod FQDN on port 5701. Confirm the sidecar is not intercepting that port in a
way that breaks the direct pod-to-pod path; excluding it is sometimes necessary:

```yaml
podAnnotations:
  traffic.sidecar.istio.io/excludeInboundPorts: "5701,5702"
  traffic.sidecar.istio.io/excludeOutboundPorts: "5701,5702"
```

If you exclude those ports from the mesh, `cluster.tls.enabled` is doing the
encryption for Raft rather than the sidecar - so it is not optional in that
configuration.
