{{/*
Create the app name based on the .Release.Name but without the -proxy suffix
*/}}
{{- define "application.name" -}}
{{- printf "%s-%s" .Release.Name | replace "-proxy" ""  }}
{{- end }}