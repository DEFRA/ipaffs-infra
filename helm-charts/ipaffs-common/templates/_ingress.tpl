{{/*
Ingress hosts
*/}}
{{- define "ipaffs-common.ingressHosts" -}}
  {{- if gt (len .Values.ingress.hosts) 0 -}}
    {{- $hosts := list -}}
    {{- range .Values.ingress.hosts }}
      {{- $host := . -}}
      {{- $hostWithSuffix := printf "%s-%s.imp.%s.azure.defra.cloud" $host $.Values.environment $.Values.environment -}}
      {{- $hosts = append $hosts $host }}
      {{- $hosts = append $hosts $hostWithSuffix }}
    {{- end -}}
    {{- $hosts | join "\n" -}}
  {{- end -}}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
