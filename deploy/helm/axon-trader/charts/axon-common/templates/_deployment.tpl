{{- define "axon-common.deployment" -}}
{{- $cfg := include "axon-common.configData" . -}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "axon-common.name" . }}
  labels:
    {{- include "axon-common.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  revisionHistoryLimit: 5
  {{- with .Values.strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "axon-common.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "axon-common.labels" . | nindent 8 }}
        {{- with .Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      annotations:
        {{- if $cfg }}
        checksum/config: {{ $cfg | sha256sum }}
        {{- end }}
        {{- with .Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      serviceAccountName: {{ include "axon-common.serviceAccountName" . }}
      automountServiceAccountToken: {{ .Values.serviceAccount.automountToken }}
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      {{- if .Values.cloudSqlProxy.enabled }}
      initContainers:
        # Cloud SQL Auth Proxy as a native sidecar (restartPolicy: Always): starts before the app, stops after it, and
        # authenticates with the pod's Workload Identity. The app talks plain JDBC to 127.0.0.1; the proxy does mTLS.
        - name: cloud-sql-proxy
          image: {{ .Values.cloudSqlProxy.image | quote }}
          restartPolicy: Always
          args:
            - --structured-logs
            - --port={{ .Values.database.port }}
            - --health-check
            - --http-address=0.0.0.0
            {{- range .Values.cloudSqlProxy.extraArgs }}
            - {{ . | quote }}
            {{- end }}
            - {{ .Values.cloudSqlProxy.instanceConnectionName | quote }}
          startupProbe:
            httpGet: {path: /startup, port: 9090}
            periodSeconds: 1
            failureThreshold: 60
          livenessProbe:
            httpGet: {path: /liveness, port: 9090}
            periodSeconds: 10
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          resources:
            {{- toYaml .Values.cloudSqlProxy.resources | nindent 12 }}
      {{- end }}
      containers:
        - name: {{ include "axon-common.name" . }}
          image: {{ include "axon-common.image" . | quote }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          {{- if or $cfg .Values.secret.enabled }}
          envFrom:
            {{- if $cfg }}
            - configMapRef:
                name: {{ include "axon-common.configName" . }}
            {{- end }}
            {{- if .Values.secret.enabled }}
            - secretRef:
                name: {{ include "axon-common.secretName" . }}
            {{- end }}
          {{- end }}
          {{- with .Values.env }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          ports:
            - name: http
              containerPort: {{ .Values.containerPort }}
              protocol: TCP
          {{- with .Values.probes.startup }}
          startupProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.probes.readiness }}
          readinessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.probes.liveness }}
          livenessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 256Mi
      {{- with .Values.topologySpreadConstraints }}
      topologySpreadConstraints:
        {{- tpl (toYaml .) $ | nindent 8 }}
      {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end -}}
