{{- define "axon-common.configmap" -}}
{{- $cfg := include "axon-common.configData" . | fromYaml -}}
{{- if $cfg }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "axon-common.configName" . }}
  labels:
    {{- include "axon-common.labels" . | nindent 4 }}
data:
  {{- range $k, $v := $cfg }}
  {{ $k }}: {{ $v | toString | quote }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Non-secret settings consumed with envFrom (see the chart README, "Configuration"). The Spring Boot services get the
connection keys of application-kubernetes.properties from .Values.database / .rabbitmq / .eureka; .Values.config adds
or overrides any key (relaxed binding).
*/}}
{{- define "axon-common.configData" -}}
{{- $d := dict -}}
{{- if .Values.springProfile }}{{- $_ := set $d "SPRING_PROFILES_ACTIVE" .Values.springProfile -}}{{- end -}}
{{- with .Values.database }}{{- if .enabled }}
{{- $_ := set $d "SPRING_DATASOURCE_URL" (printf "jdbc:mysql://%s:%v/%s?%s" .host .port .name .params) -}}
{{- $_ := set $d "SPRING_DATASOURCE_USERNAME" .username -}}
{{- end }}{{- end -}}
{{- with .Values.rabbitmq }}{{- if .enabled }}
{{- $_ := set $d "SPRING_RABBITMQ_HOST" .host -}}
{{- $_ := set $d "SPRING_RABBITMQ_PORT" (toString .port) -}}
{{- $_ := set $d "SPRING_RABBITMQ_USERNAME" .username -}}
{{- $_ := set $d "SPRING_RABBITMQ_VIRTUAL_HOST" .virtualHost -}}
{{- end }}{{- end -}}
{{- with .Values.eureka }}{{- if .enabled }}
{{- $_ := set $d "EUREKA_DEFAULT_ZONE" .defaultZone -}}
{{- end }}{{- end -}}
{{- range $k, $v := .Values.config }}{{- $_ := set $d $k (toString $v) -}}{{- end -}}
{{- if $d }}{{ toYaml $d }}{{ end -}}
{{- end -}}
