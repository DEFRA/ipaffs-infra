{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "deploy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Managed identity names created by deploy-identities.yaml.
*/}}
{{- define "webapp.azure.serviceManagedIdentityName" -}}
{{- $defaultIdentityName := printf "%s-%s-%s-service" (include "ipaffs-common.azure.resourceGroup" .) .Release.Namespace .Values.service -}}
{{- .Values.azure.managedIdentityName | default $defaultIdentityName -}}
{{- end }}

{{- define "webapp.azure.migrationsManagedIdentityName" -}}
{{- $defaultIdentityName := printf "%s-%s-%s-migrations" (include "ipaffs-common.azure.resourceGroup" .) .Release.Namespace .Values.service -}}
{{- .Values.database.migrations.managedIdentityName | default $defaultIdentityName -}}
{{- end }}

{{/*
Resolve workload identity client IDs from ASO UserAssignedIdentity status.
Explicit values are still supported as a compatibility fallback.
*/}}
{{- define "webapp.azure.servicePrincipalName" -}}
{{- $principalName := .Values.database.principalName | default "" -}}
{{- if not $principalName -}}
{{- $principalName = include "webapp.azure.serviceManagedIdentityName" . -}}
{{- end -}}
{{- required "Unable to resolve service managed identity principalName." $principalName -}}
{{- end }}

{{- define "webapp.azure.serviceClientId" -}}
{{- $clientId := .Values.azure.clientId | default "" -}}
{{- if not $clientId -}}
{{- $identityName := include "webapp.azure.serviceManagedIdentityName" . -}}
{{- $identity := lookup "managedidentity.azure.com/v1api20230131" "UserAssignedIdentity" .Release.Namespace $identityName -}}
{{- if $identity -}}
{{- $status := get $identity "status" | default dict -}}
{{- $clientId = get $status "clientId" | default "" -}}
{{- end -}}
{{- end -}}
{{- required (printf "Unable to resolve service managed identity clientId. Ensure ASO UserAssignedIdentity %s has status.clientId, or set azure.clientId." (include "webapp.azure.serviceManagedIdentityName" .)) $clientId -}}
{{- end }}

{{- define "webapp.azure.migrationsClientId" -}}
{{- $clientId := .Values.database.migrations.clientId | default "" -}}
{{- if not $clientId -}}
{{- $identityName := include "webapp.azure.migrationsManagedIdentityName" . -}}
{{- $identity := lookup "managedidentity.azure.com/v1api20230131" "UserAssignedIdentity" .Release.Namespace $identityName -}}
{{- if $identity -}}
{{- $status := get $identity "status" | default dict -}}
{{- $clientId = get $status "clientId" | default "" -}}
{{- end -}}
{{- end -}}
{{- required (printf "Unable to resolve migrations managed identity clientId. Ensure ASO UserAssignedIdentity %s has status.clientId, or set database.migrations.clientId." (include "webapp.azure.migrationsManagedIdentityName" .)) $clientId -}}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
