{{/*
Azure Resource Names
*/}}
{{- define "ipaffs-common.azure.databaseName" -}}
{{- $namespaces := list "dev" "tst" "pre" "prd" -}}
{{- if has .Release.Namespace $namespaces -}}
{{- printf "%s" .databaseName -}}
{{- else -}}
{{- printf "%s-%s" .databaseName .Release.Namespace -}}
{{- end -}}
{{- end }}

{{- define "ipaffs-common.azure.managedIdentityBaseName" -}}
{{- printf "%simpinfrg1401-%s-%s" .Values.environment .Release.Namespace .Values.service }}
{{- end }}

{{- define "ipaffs-common.azure.redisName" -}}
{{- printf "%simpinfrd1401-%s-%s" .Values.environment .Values.service .Release.Namespace }}
{{- end }}

{{- define "ipaffs-common.azure.resourceGroup" -}}
{{- printf "%simpinfrg1401" .Values.environment }}
{{- end }}

{{- define "ipaffs-common.azure.serviceBusNamespace" -}}
{{ if .Values.azure.serviceBusNamespace}}
{{- printf "%s" .Values.azure.serviceBusNamespace }}
{{- else -}}
{{- printf "%simpinfsb1401-%s" .Values.environment .Release.Namespace }}
{{- end }}
{{- end }}

{{- define "ipaffs-common.azure.sqlServer" -}}
{{ if .Values.azure.sqlServer}}
{{- printf "%s" .Values.azure.sqlServer }}
{{- else -}}
{{- printf "%simpdbssq1401" .Values.environment }}
{{- end }}
{{- end }}

{{- define "ipaffs-common.azure.sqlServerHostname" -}}
{{ if .Values.azure.sqlServerHostname}}
{{- printf "%s" .Values.azure.sqlServerHostname }}
{{- else -}}
{{- printf "%simpdbssq1401.database.windows.net" .Values.environment }}
{{- end }}
{{- end }}

{{- define "ipaffs-common.azure.searchServiceName" -}}
{{ if .Values.search.serviceName}}
{{- printf "%s" .Values.search.serviceName }}
{{- else -}}
{{- printf "%impinfas1401" .Values.environment }}
{{- end }}
{{- end }}

{{- define "ipaffs-common.azure.storageAccount" -}}
{{- printf "%simpinfst1401" .Values.environment }}
{{- end }}


{{/* vim: set ts=2 sts=2 sw=2 et: */}}
