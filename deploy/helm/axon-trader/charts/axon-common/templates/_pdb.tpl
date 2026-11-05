{{- define "axon-common.pdb" -}}
{{- if .Values.podDisruptionBudget.enabled }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "axon-common.name" . }}
  labels:
    {{- include "axon-common.labels" . | nindent 4 }}
spec:
  {{- if hasKey .Values.podDisruptionBudget "minAvailable" }}
  minAvailable: {{ .Values.podDisruptionBudget.minAvailable }}
  {{- else }}
  maxUnavailable: {{ .Values.podDisruptionBudget.maxUnavailable | default 1 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "axon-common.selectorLabels" . | nindent 6 }}
{{- end }}
{{- end -}}
