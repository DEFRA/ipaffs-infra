{{/*
Azure Resource Names
*/}}
{{- define "ipaffs-common.azure.databaseName" -}}
{{- printf "%s-%s" .databaseName .Release.Namespace }}
{{- end }}

{{- define "ipaffs-common.azure.managedIdentityBaseName" -}}
{{- printf "%simpinfmi1401-%s" .Values.environment  .Values.service }}
{{- end }}

{{- define "ipaffs-common.azure.redisName" -}}
{{- printf "%simpinfrd1401-%s-%s" .Values.environment .Values.service .Release.Namespace }}
{{- end }}

{{- define "ipaffs-common.azure.resourceGroup" -}}
{{- printf "%simpinfrg1401" .Values.environment }}
{{- end }}

{{- define "ipaffs-common.azure.serviceBusNamespace" -}}
{{- printf "%simpinfsb1401-%s" .Values.environment .Release.Namespace }}
{{- end }}

{{- define "ipaffs-common.azure.sqlServer" -}}
{{- printf "%simpdbssq1401" .Values.environment }}
{{- end }}

{{- define "ipaffs-common.azure.sqlServerHostname" -}}
{{- printf "%simpdbssq1401.database.windows.net" .Values.environment }}
{{- end }}

{{- define "ipaffs-common.azure.storageAccount" -}}
{{- printf "%simpinfsto1401" .Values.environment }}
{{- end }}


{{/* vim: set ts=2 sts=2 sw=2 et: */}}
