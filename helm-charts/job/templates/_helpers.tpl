{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "deploy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Managed identity names created by deploy-identities.yaml.
*/}}
{{- define "job.azure.serviceManagedIdentityName" -}}
{{- $defaultIdentityName := printf "%s-%s-%s-service" (include "ipaffs-common.azure.resourceGroup" .) .Release.Namespace .Values.service -}}
{{- .Values.azure.managedIdentityName | default $defaultIdentityName -}}
{{- end }}

{{/*
Resolve workload identity client ID from ASO UserAssignedIdentity status.
Explicit values are still supported as a compatibility fallback.
*/}}
{{- define "job.azure.serviceClientId" -}}
{{- $azure := default (dict) .Values.azure -}}
{{- $clientId := get $azure "clientId" | default "" -}}
{{- if not $clientId -}}
{{- $identityName := include "job.azure.serviceManagedIdentityName" . -}}
{{- $identity := lookup "managedidentity.azure.com/v1api20230131" "UserAssignedIdentity" .Release.Namespace $identityName -}}
{{- if $identity -}}
{{- $status := get $identity "status" | default dict -}}
{{- $clientId = get $status "clientId" | default "" -}}
{{- end -}}
{{- end -}}
{{- $clientId -}}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
