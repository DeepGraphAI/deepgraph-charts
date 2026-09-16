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

### How the password gets set

A fresh install applies `auth.password` directly. On a volume that already
holds an admin account, the chart re-applies it at every start, which is what
`auth.enforcePassword` governs:

```yaml
auth:
  existingSecret: synapse-admin
  enforcePassword: true     # the default
```

Both run in a short-lived process that exits before the server opens the
database. That ordering matters and is not incidental: a reset performed inside
the running server persists the new hash while that same process keeps answering
from an authentication cache populated earlier, so the credential ends up
correct on disk and wrong in the process actually serving queries.

**This requires an image carrying the admin-password fix.** Earlier builds
accepted the password given to installation and discarded it, seeding a
well-known default instead - a successful install, no warning, and a database
reachable on that default. The chart checks for the `set-admin-password`
subcommand, which shipped with the fix, and refuses to start without it rather
than deploy something that looks configured and is not.

Verify it, rather than assuming:

```bash
# Should succeed
kubectl -n synapse exec -it synapse-0 -- synapse-client \
  --host 127.0.0.1 --port 50051 --user admin --password "$YOUR_PASSWORD"

# Should be rejected
kubectl -n synapse exec -it synapse-0 -- synapse-client \
  --host 127.0.0.1 --port 50051 --user admin --password admin123
```

Because it re-applies on every start, the values file stays the source of truth:
a password changed out of band with `ALTER USER` is reverted at the next
restart. To manage it in GQL instead, set `auth.enforcePassword: false`.

```gql
ALTER USER admin SET PASSWORD 'new-password';
```

Rotating through the chart is the other direction - update the Secret and
restart, and the new password is applied on the way up:

```bash
kubectl -n synapse create secret generic synapse-admin \
  --from-literal=SYNAPSE_USER=admin \
  --from-literal=SYNAPSE_PASSWORD="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n synapse rollout restart statefulset/synapse
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

Three deliberate choices in the generated policy:

- **Metrics scraping stays open cluster-wide** even when client access is
  restricted. Naming the Prometheus namespace explicitly means monitoring breaks
  silently the day it moves.
- **Raft and admin ports accept only Synapse pods of the same release.** These
  are not client ports and nothing else should reach them.
- **The chart's own `helm test` pod is allowed through** to the HTTP port. It
  runs in the release namespace, so a narrow `allowedClients` would otherwise
  block it and turn a working deployment into a failing test.

### Verify enforcement on your cluster

NetworkPolicy is enforced by the CNI, not by Kubernetes itself, and support
varies. Some implementations enforce the default-deny that a policy implies but
do not correctly match `podSelector` or `namespaceSelector` peers, which
produces a policy that blocks everything - including traffic you allowed.

That fails closed rather than open, so it is an availability problem rather than
a security one, but it is worth knowing before you find out during an incident:

```bash
# With the policy on, from a pod that should be allowed
kubectl -n applications run nettest --rm -it --image=curlimages/curl:8.11.1 -- \
  curl -sS --max-time 8 http://synapse.synapse.svc.cluster.local:8080/health
```

If that fails while the same request succeeds with the policy deleted, and
`helm test` also fails only when the policy is on, the CNI is not matching the
selectors. Check what your cluster runs (`kubectl -n kube-system get pods`) and
its NetworkPolicy support before relying on `allowedClients`.

For a locked-down namespace, deny egress too:

```yaml
networkPolicy:
  allowExternalEgress: false
```

The chart keeps a DNS rule, without which nothing resolves - including Raft peer
FQDNs. Anything else the deployment needs to reach (an OTLP collector, an
external identity provider, a data source it ingests from) must be added
explicitly via `extraManifests`. Note that `ml.enabled: true` needs egress to a
package index and the model hub, and stalls without it.

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
  `ml.enabled: false` can run as non-root; set `runAsNonRoot: true` with a
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
