{{/*
Ingress hosts
*/}}
{{- define "ipaffs-common.ingressHosts" -}}
  {{- if gt (len .Values.ingress.hosts) 0 -}}
    {{- $hosts := list -}}
    {{- range .Values.ingress.hosts }}
      {{- $suffix := eq $.Release.Namespace $.Values.environment | ternary "" (printf "-%s" $.Release.Namespace) }}
      {{- $host := printf "%s%s" . $suffix -}}
      {{- $hostWithDomain := printf "%s.aks.imp.%s.azure.defra.cloud" $host $.Values.environment -}}
      {{- $hosts = append $hosts $host }}
      {{- $hosts = append $hosts $hostWithDomain }}
    {{- end -}}
    {{- $hosts | join "\n" -}}
  {{- end -}}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
