{{/*
Ingress hosts
*/}}
{{- define "ipaffs-common.ingressHosts" -}}
  {{- if gt (len .Values.ingress.hosts) 0 -}}
    {{- $hosts := list -}}
    {{- range .Values.ingress.hosts }}
      {{- $env := eq $.Values.environment "poc" | ternary "dev" $.Values.environment }}
      {{- $_suffix := printf "-%s" $.Release.Namespace }}
      {{- $_lowerNamespace := lower $.Release.Namespace }}
      {{- $_lowerEnvironment := lower $.Values.environment }}
      {{- $suffix := eq $_lowerNamespace $_lowerEnvironment | ternary "" $_suffix }}
      {{- $host := printf "%s%s" . $suffix -}}
      {{- $hostWithDomain := printf "%s.aks.imp.%s.azure.defra.cloud" $host $env -}}
      {{- $hosts = append $hosts $host }}
      {{- $hosts = append $hosts $hostWithDomain }}
    {{- end -}}
    {{- $hosts | join "\n" -}}
  {{- end -}}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
