{{/*
Canonical base URL to use for B2B clients
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
Canonical base URL to use for B2C clients
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
      {{- printf "https://ipaffs-%s%s.azure.defra.cloud" $.Values.environment $urlSuffix }}
    {{- end -}}
  {{- else -}}
    {{- printf "https://proxy-%s.aks.imp.%s.azure.defra.cloud" $.Release.Namespace $.Values.environment }}
  {{- end -}}
{{- end }}

{{/*
Host head domain to match for B2C requests
*/}}
{{- define "ipaffs-common.ipaffsDomainB2c" -}}
  {{- $ipaffsUrls := default dict $.Values.ipaffsUrls -}}
  {{- $urlSuffix := "-new" -}}
  {{- if $ipaffsUrls.useLiveUrls -}}
    {{- $urlSuffix = "" -}}
  {{- end -}}
  {{- if eq $.Release.Namespace $.Values.environment -}}
    {{- printf "importnotification-%s%s.azure.defra.cloud" $.Values.environment $urlSuffix }}
  {{- else -}}
    {{- printf "proxy-%s.aks.imp.%s.azure.defra.cloud" $.Release.Namespace $.Values.environment }}
  {{- end -}}
{{- end }}
