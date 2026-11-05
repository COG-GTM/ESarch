{{- define "axon-common.externalsecret" -}}
{{- if and .Values.secret.enabled .Values.secret.externalSecret.enabled }}
---
# Synced from Secret Manager by External Secrets through the per-workload SecretStore (infra/k8s/platform/stores.yaml),
# which authenticates as the workload's KSA. The Secret Manager secrets are declared in infra/terraform; nothing secret
# is stored in the repo.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ include "axon-common.secretName" . }}
  labels:
    {{- include "axon-common.labels" . | nindent 4 }}
spec:
  refreshInterval: {{ .Values.secret.externalSecret.refreshInterval }}
  secretStoreRef:
    kind: SecretStore
    name: {{ .Values.secret.externalSecret.secretStore | default (printf "gcp-sm-%s" (include "axon-common.name" .)) }}
  target:
    name: {{ include "axon-common.secretName" . }}
    creationPolicy: Owner
  data:
    {{- range $key, $remote := .Values.secret.externalSecret.data }}
    - secretKey: {{ $key }}
      remoteRef:
        key: {{ $remote }}
    {{- end }}
{{- end }}
{{- end -}}
