{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "deploy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Resolve the list of database names that this chart manages.

Backwards compatibility:
- If database.managedDatabaseNames is set, use it.
- Otherwise fall back to legacy database.databaseNames.
*/}}
{{- define "backoffice.database.managedNames" -}}
{{- $database := .Values.database | default dict -}}
{{- $managedDatabaseNames := get $database "managedDatabaseNames" | default list -}}
{{- if gt (len $managedDatabaseNames) 0 -}}
{{- $managedDatabaseNames | toJson -}}
{{- else -}}
{{- get $database "databaseNames" | default list | toJson -}}
{{- end -}}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
