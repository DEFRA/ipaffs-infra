{{/* Central Java configuration replaces the image's applicationinsights.json. */}}
{{- define "ipaffs-common.telemetry.javaEnv" -}}
  {{- $telemetry := .Values.telemetry | default dict -}}
  {{- $java := $telemetry.java | default dict -}}
  {{- if $java.enabled -}}
    {{- $roleName := required "service is required when central Java telemetry is enabled" .Values.service -}}
    {{- $canonicalNamespace := $java.canonicalNamespace | default (lower .Values.environment) -}}
    {{- if ne .Release.Namespace $canonicalNamespace -}}
      {{- $roleName = printf "%s.%s" .Release.Namespace $roleName -}}
    {{- end -}}
    {{- $configuration := dict
      "role" (dict "name" $roleName)
      "customDimensions" (dict "k8s.namespace.name" .Release.Namespace)
      "jmxMetrics" ($java.jmxMetrics | default list)
    -}}
    {{- if hasKey $java "metricIntervalSeconds" -}}
      {{- $_ := set $configuration "metricIntervalSeconds" $java.metricIntervalSeconds -}}
    {{- end -}}
- name: APPLICATIONINSIGHTS_CONFIGURATION_CONTENT
  value: {{ $configuration | toJson | quote }}
  {{- end -}}
{{- end -}}
