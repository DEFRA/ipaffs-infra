{{/*
Ingress hosts
*/}}
{{- define "ipaffs-common.ingressHosts" -}}
  {{- if gt (len .Values.ingress.hosts) 0 -}}
    {{- $hosts := list -}}
    {{- range .Values.ingress.hosts }}
      {{- $host := . -}}
      {{- $env := eq $.Values.environment "poc" | ternary "dev" $.Values.environment }}
      {{- $suffix := printf "-%s" $.Release.Namespace }}
      {{- $_suffix := eq $.Release.Namespace $.Values.Environment | ternary "" $suffix }}
      {{- $hostWithSuffix := printf "%s%s.aks.imp.%s.azure.defra.cloud" $host $suffix $env -}}
      {{- $hosts = append $hosts $host }}
      {{- $hosts = append $hosts $hostWithSuffix }}
    {{- end -}}
    {{- $hosts | join "\n" -}}
  {{- end -}}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
