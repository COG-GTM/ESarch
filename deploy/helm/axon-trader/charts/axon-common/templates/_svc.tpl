{{- define "axon-common.svc" -}}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "axon-common.name" . }}
  labels:
    {{- include "axon-common.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  selector:
    {{- include "axon-common.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
{{- end -}}
