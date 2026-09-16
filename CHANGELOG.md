# Changelog

Chart versions follow semantic versioning independently of the Synapse version
they deploy. `appVersion` tracks Synapse; `version` tracks the chart.

## 0.2.0

**Breaking:** `image.repository` no longer has a default and must be set.

Synapse is not published to any public registry. The previous default,
`synapse`, resolved to `docker.io/library/synapse` - a namespace this project
does not own - and the examples pointed at a GHCR path where nothing usable is
published. Both would have sent an operator to the wrong image or to none. The
chart now fails at render time naming what to set and why, and the examples
carry an obvious placeholder.

`docs/installation.md` gains the missing half: building and pushing the image,
the two build flags that decide whether clustering and the admin password work,
wiring a pull secret, and installing while the charts repository is private.

## 0.1.0

First release. Validated against a real Synapse image on a k3s cluster, not
only by rendering - several of the defaults below exist because that testing
contradicted the obvious assumption.

### Deployment

- StatefulSet with per-pod persistent storage, gRPC on 50051 and the HTTP
  listener (UI, REST, health, metrics) on 8080.
- Optional BOLT listener for Neo4j-compatible drivers.
- Multi-node Raft clustering: per-pod configuration generated at start-up from
  the StatefulSet ordinal, seed election on ordinal 0, optional peer mTLS, and
  an admin port for `synapsectl`.
- Probes wired to `/health/live` and `/health/ready`, so a pod stays out of the
  Service until storage, catalog and the session manager are all up.
- Observability: ServiceMonitor, PrometheusRule with seven alerts, a 36-panel
  Grafana dashboard, and OTLP trace export.
- Istio `PeerAuthentication`, `Gateway`, `VirtualService` and `DestinationRule`.
  Outlier detection is omitted in cluster mode, where ejecting the leader would
  take the write path down rather than route around a bad replica.
- NetworkPolicy, PodDisruptionBudget, Ingress, and hooks for extra env, volumes,
  containers and manifests.

### Defaults that came out of testing

- **`ml.enabled: false`.** The image builds a ~4GB Python environment on first
  start whether or not any AI feature is used. The server does not need it - a
  missing environment is a start-up warning - so the chart starts the server
  directly. Measured: 20 seconds to ready, against 7m45s with the build.
- **`auth.enforcePassword: true`.** A fresh install applies `auth.password`
  directly; this governs whether it is re-applied to a volume that already holds
  an admin account, so that changing `auth.password` and upgrading actually
  rotates it. Both paths run in a process that exits before the server opens the
  database, so the server reads the new credential at boot rather than serving a
  cached one.
- **`off_row.enabled = false` in cluster mode.** Off-row payload bytes are not
  replicated; the server refuses to start a multi-node configuration with them
  on, so the chart turns them off rather than letting the pod crash-loop.

### Guards

Refused at render time: no admin password; clustering without persistence;
metrics or ingress without the HTTP listener; two license sources; `ml.enabled`
with a startup-probe budget too small for the environment build.

Refused at container start-up, where the image has to be inspected:

- Cluster mode on an image built without the `cluster` Cargo feature. Such a
  server ignores the peer list and starts alone, as would every other pod,
  producing N independent databases behind one Service that diverge from the
  first write.
- Any deployment on an image predating the admin-password fix, which discards
  the password given to installation and seeds a well-known default instead.

Both exit with an explanatory message naming the image requirement.

`values.schema.json` catches mistyped keys at install rather than ignoring them.

### Requires

A Synapse image you have built and pushed. Synapse is not published to any
public registry, so `image.repository` has no default and the chart refuses to
render without it.

That image must come from Synapse main at or after the admin-password fix - the
one carrying the `set-admin-password` subcommand, which the chart uses to
re-apply the password to an existing volume and probes for as a support check.
Cluster mode additionally needs the `cluster` Cargo feature.

### Documentation

Ten example values files, a companion Prometheus/Loki/Grafana/Tempo stack, and
eight guides. `scripts/validate.sh` renders every example plus 23 feature
combinations and asserts the guards reject what they should.
