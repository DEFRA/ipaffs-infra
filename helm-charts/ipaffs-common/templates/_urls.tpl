{{/*
Canonical base URL to use for B2B clients, for use when the host cannot be inferred from HTTP headers
*/}}
{{- define "ipaffs-common.ipaffsUrlB2b" -}}
  {{- $ipaffsUrls := default dict $.Values.ipaffsUrls -}}
  {{- $urlSuffix := "-new" -}}
  {{- if $ipaffsUrls.useLiveUrls -}}
    {{- $urlSuffix = "" -}}
  {{- end -}}
  {{- if eq $.Release.Namespace $.Values.environment -}}
    {{- printf "https://importnotification-int-%s%s.azure.defra.cloud" $.Values.environment $urlSuffix }}
  {{- else -}}
    {{- printf "https://proxy-int-%s.aks.imp.%s.azure.defra.cloud" $.Release.Namespace $.Values.environment }}
  {{- end -}}
{{- end }}

{{/*
Canonical base URL to use for B2C clients, for use when the host cannot be inferred from HTTP headers
*/}}
{{- define "ipaffs-common.ipaffsUrlB2c" -}}
  {{- $ipaffsUrls := default dict $.Values.ipaffsUrls -}}
  {{- $urlSuffix := "-new" -}}
  {{- if $ipaffsUrls.useLiveUrls -}}
    {{- $urlSuffix = "" -}}
  {{- end -}}
  {{- if eq $.Release.Namespace $.Values.environment -}}
    {{- if and $ipaffsUrls.useLiveUrls (eq $.Values.environment "prd") -}}
      {{- printf "https://import-products-animals-food-feed.service.gov.uk" -}}
    {{- else -}}
      {{- printf "https://importnotification-%s%s.azure.defra.cloud" $.Values.environment $urlSuffix }}
    {{- end -}}
  {{- else -}}
    {{- printf "https://proxy-%s.aks.imp.%s.azure.defra.cloud" $.Release.Namespace $.Values.environment }}
  {{- end -}}
{{- end }}


