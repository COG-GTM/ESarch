{{- define "axon-trader.labels" -}}
app.kubernetes.io/part-of: axon-trader
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "axon-trader.axonApps" -}}
podSelector:
  matchExpressions:
    - {key: app.kubernetes.io/name, operator: In, values: [trader-app, trading-engine]}
{{- end -}}
