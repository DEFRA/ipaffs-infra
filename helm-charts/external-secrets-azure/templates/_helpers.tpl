{{/*
Return the release name, allowing override via nameOverride.
*/}}
{{- define "external-secrets-azure.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return the ClusterSecretStore name, allowing override.
*/}}
{{- define "external-secrets-azure.fullname" -}}
{{- if .Values.secretStoreNameOverride -}}
{{- .Values.secretStoreNameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "external-secrets-azure.name" . -}}
{{- end -}}
{{- end -}}
