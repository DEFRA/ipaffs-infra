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

{{/*
Resolve an image reference.

If the supplied image already contains a registry host, return as-is.
Otherwise prefix with `.Values.imageRegistry` when provided.
*/}}
{{- define "webapp.image.resolve" -}}
{{- $image := required "Image value is required." .image -}}
{{- $parts := splitList "/" $image -}}
{{- $firstPart := first $parts -}}
{{- $hasRegistryHost := and (gt (len $parts) 1) (or (contains "." $firstPart) (contains ":" $firstPart) (eq $firstPart "localhost")) -}}
{{- if $hasRegistryHost -}}
{{- $image -}}
{{- else -}}
{{- $registry := (default "" .root.Values.imageRegistry) | trimSuffix "/" -}}
{{- if $registry -}}
{{- printf "%s/%s" $registry $image -}}
{{- else -}}
{{- $image -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Stable hashes used to trigger Deployment rollouts when referenced config/secrets change.
*/}}
{{- define "webapp.rollout.hashFromObjectData" -}}
{{- $obj := .obj -}}
{{- if $obj -}}
{{- $payload := dict "data" (get $obj "data" | default dict) "binaryData" (get $obj "binaryData" | default dict) -}}
{{- toJson $payload | sha256sum -}}
{{- else -}}
absent
{{- end -}}
{{- end }}

{{- define "webapp.rollout.serviceConfigChecksum" -}}
{{- $data := dict "ENVIRONMENT" (printf "%v" .Values.environment) -}}
{{- range $databaseName := .Values.database.databaseNames }}
{{- $db := dict "databaseName" $databaseName "Values" $.Values "Release" $.Release -}}
{{- $key := printf "DATABASE_DB_CONNECTION_STRING_%s" (upper (snakecase $databaseName)) -}}
{{- $value := printf "jdbc:sqlserver://%s:1433;databaseName=%s;encrypt=true;socketTimeout=1800000;loginTimeout=15;authentication=ActiveDirectoryManagedIdentity;msiClientId=%s" (include "ipaffs-common.azure.sqlServerHostname" $db) (include "ipaffs-common.azure.databaseName" $db) (include "webapp.azure.serviceClientId" $) -}}
{{- $_ := set $data $key $value -}}
{{- end }}
{{- range $key, $val := .Values.config }}
{{- $_ := set $data $key (printf "%v" $val) -}}
{{- end }}
{{- toJson $data | sha256sum -}}
{{- end }}

{{- define "webapp.rollout.ipaffsConfigChecksum" -}}
{{- $cm := lookup "v1" "ConfigMap" .Release.Namespace "ipaffs-config" -}}
{{- include "webapp.rollout.hashFromObjectData" (dict "obj" $cm) -}}
{{- end }}

{{- define "webapp.rollout.secretChecksum" -}}
{{- $secret := lookup "v1" "Secret" .namespace .name -}}
{{- include "webapp.rollout.hashFromObjectData" (dict "obj" $secret) -}}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
