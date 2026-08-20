{{- define "axon-trader.labels" -}}
app.kubernetes.io/part-of: axon-trader
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "axon-trader.selectorLabels" -}}
app.kubernetes.io/part-of: axon-trader
{{- end }}

{{- define "axon-trader.traderAppName" -}}trader-app{{- end }}
{{- define "axon-trader.tradingEngineName" -}}trading-engine{{- end }}
{{- define "axon-trader.discoveryName" -}}discovery-server{{- end }}
{{- define "axon-trader.uiName" -}}trader-app-ui{{- end }}

{{- define "axon-trader.backendEnv" -}}
- name: SPRING_PROFILES_ACTIVE
  value: cloud
- name: SPRING_CONFIG_LOCATION
  value: classpath:/,classpath:/config/,file:/config/
- name: SPRING_CLOUD_BOOTSTRAP_ENABLED
  value: "false"
- name: SPRING_CLOUD_ENABLED
  value: "false"
- name: SPRING_CLOUD_CONFIG_ENABLED
  value: "false"
- name: MANAGEMENT_CLOUDFOUNDRY_ENABLED
  value: "false"
- name: SPRING_CLOUD_SERVICES_REGISTRATIONMETHOD
  value: direct
- name: EUREKA_CLIENT_SERVICEURL_DEFAULTZONE
  value: http://{{ include "axon-trader.discoveryName" . }}:{{ .Values.eureka.port }}/eureka/
- name: EUREKA_INSTANCE_PREFERIPADDRESS
  value: "true"
- name: JAVA_OPTS
  value: "-Deureka.client.serviceUrl.defaultZone=http://{{ include "axon-trader.discoveryName" . }}:{{ .Values.eureka.port }}/eureka/"
- name: JAVA_MAX_RAM_PERCENTAGE
  value: {{ .Values.javaMaxRamPercentage | quote }}
- name: SPRING_RABBITMQ_PORT
  value: {{ .Values.rabbitmq.port | quote }}
- name: SPRING_RABBITMQ_USERNAME
  valueFrom:
    secretKeyRef:
      name: axon-trader-credentials
      key: rabbitmq-username
- name: SPRING_RABBITMQ_PASSWORD
  valueFrom:
    secretKeyRef:
      name: axon-trader-credentials
      key: rabbitmq-password
- name: SPRING_RABBITMQ_HOST
  value: {{ .Values.rabbitmq.host | quote }}
{{- end }}
