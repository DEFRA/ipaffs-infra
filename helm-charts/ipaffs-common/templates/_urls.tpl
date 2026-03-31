{{/*
Canonical base URL to use for B2B clients, for use when the host cannot be inferred from HTTP headers
*/}}
{{- define "ipaffs-common.ipaffsUrlB2b" -}}
  {{- if eq $.Release.Namespace $.Values.environment -}}
    {{- printf "https://importnotification-int-%s.azure.defra.cloud" $.Values.environment }}
  {{- else -}}
    {{- printf "http://proxy-int-%s.aks.imp.%s.azure.defra.cloud" $.Release.Namespace $.Values.environment }}
  {{- end -}}
{{- end }}

{{/*
Canonical base URL to use for B2C clients, for use when the host cannot be inferred from HTTP headers
*/}}
{{- define "ipaffs-common.ipaffsUrlB2c" -}}
  {{- if eq $.Release.Namespace $.Values.environment -}}
    {{- if eq $.Values.Environment "prd" -}}
      {{- printf "https://import-products-animals-food-feed.service.gov.uk" -}}
    {{- else -}}
      {{- printf "https://importnotification-%s.azure.defra.cloud" $.Values.environment }}
    {{- end -}}
  {{- else -}}
    {{- printf "http://proxy-%s.aks.imp.%s.azure.defra.cloud" $.Release.Namespace $.Values.environment }}
  {{- end -}}
{{- end }}


{{/* vim: set ts=2 sts=2 sw=2 et: */}}
