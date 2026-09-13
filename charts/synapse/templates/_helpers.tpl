{{/*
Expand the name of the chart.
*/}}
{{- define "synapse.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "synapse.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "synapse.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every object.

Built as a dict and merged rather than concatenated as text: commonLabels
may legitimately override one of the chart's own keys (app.kubernetes.io/
part-of is the usual one), and emitting both lines produces YAML with a
duplicate key, which the API server rejects.

merge gives precedence to the first argument, so commonLabels wins.
*/}}
{{- define "synapse.labels" -}}
{{- $base := dict
    "helm.sh/chart" (include "synapse.chart" .)
    "app.kubernetes.io/name" (include "synapse.name" .)
    "app.kubernetes.io/instance" .Release.Name
    "app.kubernetes.io/managed-by" .Release.Service
    "app.kubernetes.io/component" "database"
    "app.kubernetes.io/part-of" "synapse" -}}
{{- if .Chart.AppVersion -}}
{{- $_ := set $base "app.kubernetes.io/version" (.Chart.AppVersion | toString) -}}
{{- end -}}
{{- toYaml (merge (deepCopy (default dict .Values.commonLabels)) $base) -}}
{{- end }}

{{/*
Pod labels: the selector labels, plus commonLabels and podLabels merged in
the same duplicate-safe way. podLabels wins over commonLabels.
*/}}
{{- define "synapse.podLabels" -}}
{{- $base := dict
    "app.kubernetes.io/name" (include "synapse.name" .)
    "app.kubernetes.io/instance" .Release.Name -}}
{{- $merged := merge (deepCopy (default dict .Values.podLabels)) (deepCopy (default dict .Values.commonLabels)) $base -}}
{{- toYaml $merged -}}
{{- end }}

{{/*
Annotations for a given object: commonAnnotations merged with an
object-specific map. The specific map wins.
*/}}
{{- define "synapse.annotations" -}}
{{- $specific := default dict .specific -}}
{{- $common := default dict .root.Values.commonAnnotations -}}
{{- $merged := merge (deepCopy $specific) (deepCopy $common) -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end }}

{{/*
Selector labels. Immutable across upgrades - never add anything version-bearing.
*/}}
{{- define "synapse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "synapse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "synapse.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "synapse.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "synapse.headlessServiceName" -}}
{{- printf "%s-headless" (include "synapse.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "synapse.configMapName" -}}
{{- default (printf "%s-config" (include "synapse.fullname" .)) .Values.config.existingConfigMap }}
{{- end }}

{{- define "synapse.secretName" -}}
{{- default (printf "%s-credentials" (include "synapse.fullname" .)) .Values.auth.existingSecret }}
{{- end }}

{{/*
Container image reference. Tag falls back to the chart's appVersion.
*/}}
{{- define "synapse.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{/*
Whether the chart is running in multi-node (Raft) mode.
*/}}
{{- define "synapse.clusterEnabled" -}}
{{- if and .Values.cluster.enabled (gt (int .Values.replicaCount) 1) -}}true{{- else -}}false{{- end -}}
{{- end }}

{{/*
Pod FQDN for a given StatefulSet ordinal.
*/}}
{{- define "synapse.podFqdn" -}}
{{- printf "%s-%d.%s.%s.svc.%s" (include "synapse.fullname" .root) (int .ordinal) (include "synapse.headlessServiceName" .root) .root.Release.Namespace .root.Values.clusterDomain -}}
{{- end }}

{{/*
Path of the effective synapse.toml the server reads.

Single-node: the mounted ConfigMap is read directly.
Cluster: the bootstrap script copies the base and appends a per-pod
[cluster] section, so the effective file lives on a writable emptyDir.
*/}}
{{- define "synapse.configPath" -}}
{{- if eq (include "synapse.clusterEnabled" .) "true" -}}
/run/synapse/synapse.toml
{{- else -}}
/etc/synapse/synapse.toml
{{- end -}}
{{- end }}

{{/*
Guard: the HTTP listener carries /health, /health/ready and /metrics.
Probes, the ServiceMonitor, the Ingress and the UI all depend on it.
*/}}
{{- define "synapse.validate" -}}
{{- if and (not .Values.server.http.enabled) .Values.observability.serviceMonitor.enabled -}}
{{- fail "observability.serviceMonitor.enabled requires server.http.enabled - /metrics is only served on the HTTP listener" -}}
{{- end -}}
{{- if and (not .Values.server.http.enabled) .Values.ingress.enabled -}}
{{- fail "ingress.enabled requires server.http.enabled - the UI and REST API are only served on the HTTP listener" -}}
{{- end -}}
{{- if and .Values.cluster.enabled (not .Values.persistence.data.enabled) -}}
{{- fail "cluster.enabled requires persistence.data.enabled - the Raft log must survive a pod restart" -}}
{{- end -}}
{{- if and (not .Values.auth.password) (not .Values.auth.existingSecret) -}}
{{- fail "set auth.password or auth.existingSecret - refusing to deploy with an unset admin password" -}}
{{- end -}}
{{- if and .Values.tier.licenseKey .Values.tier.existingLicenseSecret -}}
{{- fail "set either tier.licenseKey or tier.existingLicenseSecret, not both" -}}
{{- end -}}
{{- end }}
