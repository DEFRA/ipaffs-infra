{{/*
Canonical base URL to use for B2B clients
*/}}
{{- define "ipaffs-common.ipaffsUrlB2b" -}}
  {{- if eq $.Release.Namespace $.Values.environment -}}
    {{- printf "https://importnotification-int-%s.azure.defra.cloud" $.Values.environment }}
  {{- else -}}
    {{- printf "https://proxy-int-%s.aks.imp.%s.azure.defra.cloud" $.Release.Namespace $.Values.environment }}
  {{- end -}}
{{- end }}

{{/*
Canonical base URL to use for B2C clients
*/}}
{{- define "ipaffs-common.ipaffsUrlB2c" -}}
  {{- if eq $.Release.Namespace $.Values.environment -}}
    {{- if eq $.Values.environment "prd" -}}
      {{- printf "https://import-products-animals-food-feed.service.gov.uk" -}}
    {{- else -}}
      {{- printf "https://ipaffs-%s.azure.defra.cloud" $.Values.environment }}
    {{- end -}}
  {{- else -}}
    {{- printf "https://proxy-%s.aks.imp.%s.azure.defra.cloud" $.Release.Namespace $.Values.environment }}
  {{- end -}}
{{- end }}

{{/*
Host head domain to match for B2C requests
*/}}
{{- define "ipaffs-common.ipaffsDomainB2c" -}}
  {{- if eq $.Release.Namespace $.Values.environment -}}
    {{- printf "importnotification-%s.azure.defra.cloud" $.Values.environment }}
  {{- else -}}
    {{- printf "proxy-%s.aks.imp.%s.azure.defra.cloud" $.Release.Namespace $.Values.environment }}
  {{- end -}}
{{- end }}
