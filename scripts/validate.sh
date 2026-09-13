#!/usr/bin/env bash
#
# Render every example and feature combination, and validate the output against
# the Kubernetes API schemas. Run before committing a template change.
#
# Requires: helm. kubeconform is used when present and skipped otherwise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${REPO_ROOT}/charts/synapse"
KUBE_VERSION="${KUBE_VERSION:-1.29.0}"

pass=0
fail=0

have_kubeconform=0
if command -v kubeconform >/dev/null 2>&1; then
    have_kubeconform=1
else
    echo "note: kubeconform not found; checking rendering only"
fi

check() {
    local name="$1"; shift
    local out
    if ! out=$(helm template test "${CHART}" --namespace synapse "$@" 2>&1); then
        printf '  FAIL  %-45s (render)\n' "${name}"
        echo "${out}" | sed 's/^/          /' | tail -5
        fail=$((fail + 1))
        return
    fi
    if [ "${have_kubeconform}" = 1 ]; then
        local res
        res=$(printf '%s' "${out}" \
            | kubeconform -strict -summary -ignore-missing-schemas \
                -kubernetes-version "${KUBE_VERSION}" 2>&1) || true
        case "${res}" in
            *"Invalid: 0, Errors: 0"*) ;;
            *)
                printf '  FAIL  %-45s (schema)\n' "${name}"
                echo "${res}" | sed 's/^/          /' | head -5
                fail=$((fail + 1))
                return
                ;;
        esac
    fi
    local n
    n=$(printf '%s' "${out}" | grep -c '^kind:' || true)
    printf '  ok    %-45s %s objects\n' "${name}" "${n}"
    pass=$((pass + 1))
}

# A render that must fail. Guards are part of the contract: silently accepting
# a broken combination is worse than refusing it.
check_rejects() {
    local name="$1"; shift
    if helm template test "${CHART}" --namespace synapse "$@" >/dev/null 2>&1; then
        printf '  FAIL  %-45s (should have been rejected)\n' "${name}"
        fail=$((fail + 1))
    else
        printf '  ok    %-45s rejected\n' "${name}"
        pass=$((pass + 1))
    fi
}

echo "==> helm lint"
helm lint "${CHART}" --set auth.password=test123

echo
echo "==> examples"
for f in "${REPO_ROOT}"/examples/*.yaml; do
    [ "$(basename "${f}")" = "README.md" ] && continue
    check "$(basename "${f}")" -f "${f}"
done

echo
echo "==> feature combinations"
check "defaults" --set auth.password=t
check "existing secret" --set auth.existingSecret=s
check "http disabled" --set auth.password=t --set server.http.enabled=false
check "bolt enabled" --set auth.password=t --set server.bolt.enabled=true
check "no persistence" --set auth.password=t --set persistence.data.enabled=false
check "ml runtime on" --set auth.password=t --set ml.enabled=true \
    --set ml.models=all --set ml.persistence.models.enabled=true \
    --set probes.startup.failureThreshold=240
check "ml runtime on, no persistence" --set auth.password=t --set ml.enabled=true \
    --set ml.persistence.mlEnv.enabled=false --set probes.startup.failureThreshold=240
check "cluster + ml runtime" --set auth.password=t --set cluster.enabled=true \
    --set replicaCount=3 --set ml.enabled=true --set probes.startup.failureThreshold=300
check "cluster 3" --set auth.password=t --set cluster.enabled=true --set replicaCount=3
check "cluster 5 + tls" --set auth.password=t --set cluster.enabled=true \
    --set replicaCount=5 --set cluster.tls.enabled=true --set cluster.tls.existingSecret=tls
check "cluster + raft timing" --set auth.password=t --set cluster.enabled=true \
    --set replicaCount=3 --set cluster.raft.heartbeatIntervalMs=500 \
    --set cluster.raft.electionTimeoutMinMs=2500 --set cluster.raft.electionTimeoutMaxMs=5000
check "observability" --set auth.password=t \
    --set observability.serviceMonitor.enabled=true \
    --set observability.prometheusRule.enabled=true \
    --set observability.grafanaDashboard.enabled=true \
    --set observability.otel.enabled=true
check "istio full" --set auth.password=t --set serviceMesh.istio.enabled=true \
    --set serviceMesh.istio.gateway.enabled=true \
    --set serviceMesh.istio.virtualService.enabled=true \
    --set serviceMesh.istio.destinationRule.enabled=true
check "istio + gateway tls" --set auth.password=t --set serviceMesh.istio.enabled=true \
    --set serviceMesh.istio.gateway.enabled=true \
    --set serviceMesh.istio.gateway.tls.enabled=true \
    --set serviceMesh.istio.gateway.tls.credentialName=cert
check "ingress + tls" --set auth.password=t --set ingress.enabled=true \
    --set ingress.tls[0].secretName=tls --set ingress.tls[0].hosts[0]=a.example.com
check "networkpolicy closed egress" --set auth.password=t \
    --set networkPolicy.enabled=true --set networkPolicy.allowExternalEgress=false
check "pdb + nodeport" --set auth.password=t --set podDisruptionBudget.enabled=true \
    --set service.type=NodePort --set service.nodePorts.grpc=30051
check "external auth" --set auth.password=t --set externalAuth.enabled=true \
    --set externalAuth.existingSecret=ext
check "license inline" --set auth.password=t --set tier.licenseKey=abc
check "digest pin" --set auth.password=t \
    --set image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000
check "fullnameOverride" --set auth.password=t --set fullnameOverride=db
check "label collision" --set auth.password=t \
    --set commonLabels."app\.kubernetes\.io/part-of"=platform \
    --set commonAnnotations.k=common --set podAnnotations.k=pod \
    --set service.annotations.k=svc

echo
echo "==> guards (these must be rejected)"
check_rejects "no password"
check_rejects "cluster without persistence" --set auth.password=t \
    --set cluster.enabled=true --set persistence.data.enabled=false
check_rejects "servicemonitor without http" --set auth.password=t \
    --set server.http.enabled=false --set observability.serviceMonitor.enabled=true
check_rejects "ingress without http" --set auth.password=t \
    --set server.http.enabled=false --set ingress.enabled=true
check_rejects "two license sources" --set auth.password=t \
    --set tier.licenseKey=a --set tier.existingLicenseSecret=b
check_rejects "ml runtime with too small a startup budget" --set auth.password=t \
    --set ml.enabled=true --set probes.startup.failureThreshold=60

echo
echo "==> ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
