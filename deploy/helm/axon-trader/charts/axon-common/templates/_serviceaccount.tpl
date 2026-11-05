{{- define "axon-common.serviceaccount" -}}
{{- if .Values.serviceAccount.create }}
---
# Workload Identity: the KSA maps to the GSA in iam.gke.io/gcp-service-account (Terraform foundation module,
# enable_gke_workload_identity_bindings). Services without a GSA get no annotation and no API token.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "axon-common.serviceAccountName" . }}
  labels:
    {{- include "axon-common.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.gcpServiceAccount }}
  annotations:
    iam.gke.io/gcp-service-account: {{ . | quote }}
  {{- end }}
automountServiceAccountToken: {{ .Values.serviceAccount.automountToken }}
{{- end }}
{{- end -}}
