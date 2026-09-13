# Security

What the chart does by default, what it leaves to you, and where the sharp edges
are.

## Credentials

`auth.password` has no default and the chart refuses to render without it or
`auth.existingSecret`. A database that ships with a known password on reachable
ports is not a useful default, so there isn't one.

Use `existingSecret` for anything beyond a laptop:

```bash
kubectl -n synapse create secret generic synapse-admin \
  --from-literal=SYNAPSE_USER=admin \
  --from-literal=SYNAPSE_PASSWORD="$(openssl rand -base64 24)"
```

```yaml
auth:
  existingSecret: synapse-admin
```

The difference is not cosmetic. `auth.password` is stored in the Helm release
Secret in plaintext, which means `helm get values` prints it, and it stays in
release history across upgrades. With `existingSecret` the chart only ever
references the name.

**These credentials apply only on first start**, against an empty data
directory. Changing them later updates the Secret and changes nothing about who
can log in. Rotate through GQL instead:

```gql
ALTER USER admin SET PASSWORD 'new-password';
```

An existing Secret may use any key names:

```yaml
auth:
  existingSecret: synapse-admin
  secretKeys:
    username: username
    password: password
```

### External identity providers

```yaml
externalAuth:
  enabled: true
  existingSecret: synapse-external-auth   # holds an external-auth.toml key
```

The file is mounted read-only and pointed at with
`SYNAPSE_EXTERNAL_AUTH_CONFIG`. It fully replaces any `[external_auth]` section
in the main config. If the file is present but unreadable or invalid, the server
exits rather than starting without the auth you asked for.

## Transport

This is the part worth being explicit about, because none of these protocols
encrypt themselves in the chart's default configuration.

| Port | Encrypted by default | How to protect it |
|---|---|---|
| 50051 gRPC | No | Service mesh mTLS, or `--mtls-auth` with mounted certs |
| 8080 HTTP | No | Ingress TLS termination, or a mesh |
| 7687 BOLT | No | Mesh, or BOLT TLS settings with a mounted keypair |
| 5701 Raft | No | `cluster.tls.enabled` - see below |

Inside a single cluster with a NetworkPolicy restricting who can connect, plain
text between pods is a defensible position. Across trust boundaries it is not.

### Raft

`cluster.tls.enabled` is `false` by default and the server logs a warning on
every start when it is off, because the Raft port carries every replicated
write. Turn it on in production:

```yaml
cluster:
  tls:
    enabled: true
    existingSecret: synapse-cluster-tls   # ca.crt, tls.crt, tls.key
```

See [clustering.md](clustering.md#issuing-the-cluster-certificate) for issuing
it. The certificate needs both `server auth` and `client auth` usages: Raft
peers are simultaneously both.

## Network policy

Off by default, since a policy that blocks the wrong thing is worse than none at
all on a first install. Turn it on once you know who the clients are:

```yaml
networkPolicy:
  enabled: true
  allowedClients:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: applications
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: analytics
      podSelector:
        matchLabels:
          app: notebook
```

Empty `allowedClients` means every pod in the release namespace, which is a
reasonable starting point but not a restriction worth much.

Two deliberate choices in the generated policy:

- **Metrics scraping stays open cluster-wide** even when client access is
  restricted. Naming the Prometheus namespace explicitly means monitoring breaks
  silently the day it moves.
- **Raft and admin ports accept only Synapse pods of the same release.** These
  are not client ports and nothing else should reach them.

For a locked-down namespace, deny egress too:

```yaml
networkPolicy:
  allowExternalEgress: false
```

The chart keeps a DNS rule, without which nothing resolves - including Raft peer
FQDNs. Anything else the deployment needs to reach (an OTLP collector, an
external identity provider, a data source it ingests from) must be added
explicitly via `extraManifests`. Note that `ml.models` other than `none` needs
egress to the model hub and will hang without it.

## Pod and container hardening

```yaml
podSecurityContext:
  runAsNonRoot: false
  runAsUser: 0
  fsGroup: 0
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false
  capabilities:
    drop:
      - ALL
```

Two of these are not as tight as they look, and both are honest reflections of
what the image needs:

- **`runAsUser: 0`.** First-run setup writes into `/app` - the Python
  environment, the model cache. An image built with those pre-staged and
  `ml.models: none` can run as non-root; set `runAsNonRoot: true` with a
  matching `runAsUser`/`fsGroup` and test it.
- **`readOnlyRootFilesystem: false`.** Same reason. Turning it on with a
  first-run image produces a crash at start-up, not a security improvement.

The service account token is not mounted (`automountServiceAccountToken: false`)
because Synapse calls no Kubernetes API. Only set it true if you add a sidecar
that needs one.

For Pod Security Standards, the defaults satisfy `baseline`. `restricted`
requires the non-root configuration above.

## Debug endpoints

```yaml
server:
  http:
    debugEndpoints: false   # the default
```

`/debug/memory`, `/debug/queries`, `/debug/indexes` and `/debug/state` expose
memory maps, in-flight query text and index internals. They have no
authentication of their own, so anyone who can reach port 8080 can read them.
The chart defaults them off and prints a warning if you turn them on.

## Exposure checklist

Before publishing Synapse outside the cluster:

- [ ] `auth.existingSecret`, with a generated password
- [ ] TLS terminated somewhere - Ingress, mesh gateway, or load balancer
- [ ] `server.http.debugEndpoints: false`
- [ ] `networkPolicy.enabled: true` with a real `allowedClients`
- [ ] `cluster.tls.enabled: true` if clustered
- [ ] Rate limiting on the Ingress - see [example 06](../examples/06-ingress-tls.yaml)
- [ ] GQL users and roles created for applications, rather than sharing the admin account
- [ ] A backup that has been restored at least once

## Secrets the chart may create

| Secret | When | Holds |
|---|---|---|
| `<release>-credentials` | `auth.existingSecret` unset | Admin username and password |
| `<release>-license` | `tier.licenseKey` set | License key |
| `<release>-external-auth` | `externalAuth.config` set | External auth TOML |

Each has an `existingSecret` alternative. Prefer them: values files end up in
git, and Helm release history keeps what was passed.
