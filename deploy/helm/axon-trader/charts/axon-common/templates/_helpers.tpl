{{/*
Named templates are global to a Helm release, so the service subcharts (trading-engine, trader-app, discovery-server,
trader-ui) call these with their own context: {{ include "axon-common.service" . }}.
Resource names are the chart name on purpose: Eureka (EUREKA_DEFAULT_ZONE), the NetworkPolicies and the platform
PodMonitoring address the services by name and by the app.kubernetes.io/name label.
*/}}
{{- define "axon-common.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "axon-common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "axon-common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "axon-common.labels" -}}
{{ include "axon-common.selectorLabels" . }}
app.kubernetes.io/part-of: axon-trader
app.kubernetes.io/version: {{ include "axon-common.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "axon-common.imageTag" -}}
{{- .Values.image.tag | default .Values.global.image.tag | default .Chart.AppVersion -}}
{{- end -}}

{{- define "axon-common.image" -}}
{{- $registry := .Values.image.registry | default .Values.global.image.registry -}}
{{- $repo := .Values.image.repository -}}
{{- if $registry }}{{ printf "%s/%s:%s" $registry $repo (include "axon-common.imageTag" .) }}{{ else }}{{ printf "%s:%s" $repo (include "axon-common.imageTag" .) }}{{ end -}}
{{- end -}}

{{- define "axon-common.serviceAccountName" -}}
{{- .Values.serviceAccount.name | default (include "axon-common.name" .) -}}
{{- end -}}

{{- define "axon-common.secretName" -}}
{{- .Values.secret.name | default (printf "%s-secrets" (include "axon-common.name" .)) -}}
{{- end -}}

{{- define "axon-common.configName" -}}
{{- printf "%s-config" (include "axon-common.name" .) -}}
{{- end -}}

{{/* Everything a service subchart renders, in one call. */}}
{{- define "axon-common.service" -}}
{{ include "axon-common.serviceaccount" . }}
{{ include "axon-common.configmap" . }}
{{ include "axon-common.externalsecret" . }}
{{ include "axon-common.deployment" . }}
{{ include "axon-common.svc" . }}
{{ include "axon-common.pdb" . }}
{{ include "axon-common.hpa" . }}
{{- end -}}
