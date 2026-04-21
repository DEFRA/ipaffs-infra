{{/*
Ingress hosts for direct services
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

{{/*
Ingress hosts for Azure Front Door origins
*/}}
{{- define "ipaffs-common.ingressOriginHosts" -}}
  {{- $suffix := eq $.Release.Namespace $.Values.environment | ternary "" (printf "-%s" $.Release.Namespace) -}}
  {{- $hosts := list -}}
  {{- $hosts = append $hosts (printf "importnotification-%s%s.azure.defra.cloud" $.Values.environment $suffix) -}}
  {{- $hosts = append $hosts (printf "importnotification-int-%s%s.azure.defra.cloud" $.Values.environment $suffix) -}}
  {{- $hosts = append $hosts (printf "importnotification-api-%s%s.azure.defra.cloud" $.Values.environment $suffix) -}}
  {{- $hosts = append $hosts (printf "importnotification-%s%s-new.azure.defra.cloud" $.Values.environment $suffix) -}}
  {{- $hosts = append $hosts (printf "importnotification-int-%s%s-new.azure.defra.cloud" $.Values.environment $suffix) -}}
  {{- $hosts = append $hosts (printf "importnotification-api-%s%s-new.azure.defra.cloud" $.Values.environment $suffix) -}}
  {{- $hosts | join "\n" -}}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
