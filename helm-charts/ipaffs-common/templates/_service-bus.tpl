{{/* Route every Service Bus connection name to the ASO-generated service secret. */}}
{{- define "ipaffs-common.serviceBus.env" -}}
{{- $serviceBus := .Values.serviceBus | default dict -}}
{{- if and $serviceBus.enabled $serviceBus.useSecrets -}}
{{- $secretKey := $serviceBus.connectionStringSecretKey | default "SERVICE_BUS_CONNECTION_STRING" -}}
{{- range uniq (concat (list $secretKey) ($serviceBus.connectionStringAliases | default list)) }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-servicebus" $.Values.service }}
      key: {{ $secretKey }}
      optional: false
{{- end -}}
{{- end -}}
{{- end -}}
