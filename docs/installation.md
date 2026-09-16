# Installation

## Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes 1.23+ | `persistentVolumeClaimRetentionPolicy` needs 1.27 for the default `Retain` behaviour to be honoured; on older clusters the field is ignored and PVCs are kept anyway |
| Helm 3.8+ | |
| A StorageClass | Must provision `ReadWriteOnce`. SSD-backed for anything beyond evaluation |
| Access to the image | `ghcr.io/deepgraphai/synapse`, or a mirror in your own registry |

Check what you have:

```bash
kubectl version --short
helm version --short
kubectl get storageclass
```

## Install

```bash
helm repo add synapse https://deepgraphai.github.io/deepgraph-charts
helm repo update
```

Create the credentials Secret first, so the password never enters a values file
or Helm's release history:

```bash
kubectl create namespace synapse

kubectl -n synapse create secret generic synapse-admin \
  --from-literal=SYNAPSE_USER=admin \
  --from-literal=SYNAPSE_PASSWORD="$(openssl rand -base64 24)"
```

Then install:

```bash
helm install synapse synapse/synapse \
  --namespace synapse \
  --set auth.existingSecret=synapse-admin \
  --set persistence.data.size=200Gi \
  --set persistence.data.storageClass=gp3
```

Or from an example file, which is usually clearer than a pile of `--set` flags:

```bash
helm install synapse synapse/synapse -n synapse \
  -f examples/02-single-node-production.yaml
```

### Watch it come up

```bash
kubectl -n synapse rollout status statefulset/synapse
kubectl -n synapse logs -f synapse-0
```

First start runs installation against the empty data directory to create the
catalog and the admin user, applies the configured admin password, then starts
the server. With the default `ml.enabled: false` that takes about 20 seconds.

With `ml.enabled: true` the first start also builds a ~4GB Python environment,
which measured at roughly 8 minutes on a 4-vCPU node with no model downloads and
is documented by the image as taking 15-30 minutes. Later starts reuse the
persisted environment and are fast again.

### Verify

```bash
helm test synapse -n synapse
```

The test pod checks `/health`, `/health/ready` and `/metrics` from inside the
cluster. Manually:

```bash
kubectl -n synapse port-forward svc/synapse 8080:8080 50051:50051

curl -s localhost:8080/health | jq
curl -s localhost:8080/health/ready | jq
open http://localhost:8080
```

A GQL console inside the pod:

```bash
kubectl -n synapse exec -it synapse-0 -- \
  synapse gql --host 127.0.0.1 --port 50051 --user admin
```

```gql
CREATE GRAPH IF NOT EXISTS /demo;
SESSION SET GRAPH /demo;
INSERT (p:Person {id: 1, name: 'Alice'});
MATCH (p:Person) RETURN p.id, p.name;
```

## Air-gapped install

Mirror the image and pull the chart as a package:

```bash
# On a connected machine
helm pull synapse/synapse --version 0.1.0
docker pull ghcr.io/deepgraphai/synapse:0.1.0
docker save ghcr.io/deepgraphai/synapse:0.1.0 | gzip > synapse-image.tar.gz

# Transfer synapse-0.1.0.tgz and synapse-image.tar.gz, then inside
docker load < synapse-image.tar.gz
docker tag ghcr.io/deepgraphai/synapse:0.1.0 registry.internal/synapse:0.1.0
docker push registry.internal/synapse:0.1.0

helm install synapse ./synapse-0.1.0.tgz -n synapse -f examples/07-air-gapped.yaml
```

Keep `ml.enabled: false`, which is the default. With it on, first start tries to
reach a public package index and the model hub; with no egress that attempt
stalls until the startup probe expires, and the pod crash-loops with an error
that does not obviously point at networking.

## Upgrade

```bash
helm repo update
helm diff upgrade synapse synapse/synapse -n synapse -f my-values.yaml   # if helm-diff is installed
helm upgrade synapse synapse/synapse -n synapse -f my-values.yaml
```

A StatefulSet rolling update replaces pods one at a time, highest ordinal first,
waiting for each to pass readiness. Single-node deployments therefore have a
restart window equal to shutdown plus start-up plus index rebuild.

Two things that are **not** changeable by upgrade:

- **`volumeClaimTemplates`.** Kubernetes rejects edits to a StatefulSet's volume
  claim templates, so `persistence.data.size` and `storageClass` cannot be
  changed in place. To grow a volume, expand the PVC directly (if the
  StorageClass allows it) and set the matching value so future replicas match:

  ```bash
  kubectl -n synapse patch pvc data-synapse-0 \
    -p '{"spec":{"resources":{"requests":{"storage":"1Ti"}}}}'
  ```

- **`auth.username`.** The server always bootstraps its admin account under a
  fixed name; this value is only used for client connections.

  `auth.password` *is* re-applied on every start while
  `auth.enforcePassword` is on, so changing it and upgrading does rotate the
  password. See [security.md](security.md#how-the-password-actually-gets-set).

### Changing the chart version

```bash
helm upgrade synapse synapse/synapse -n synapse --version 0.2.0 -f my-values.yaml
```

Read the release notes first. Anything that alters the StatefulSet's selector
labels requires a delete-and-recreate of the StatefulSet, which the notes will
say explicitly.

## Rollback

```bash
helm history synapse -n synapse
helm rollback synapse 3 -n synapse
```

Rollback reverts the manifests. It does not revert data: any writes committed
under the newer version are still in the volume, and a rollback across a storage
format change is not supported. Treat rollback as a fix for a bad configuration,
not a bad migration.

## Uninstall

```bash
helm uninstall synapse -n synapse
```

PVCs survive by default (`persistence.data.retentionPolicy.whenDeleted:
Retain`), so reinstalling into the same namespace with the same release name
picks the data back up. To remove the data as well:

```bash
kubectl -n synapse delete pvc -l app.kubernetes.io/name=synapse
```

That is irreversible. Take a backup first - see
[storage.md](storage.md#backups).
