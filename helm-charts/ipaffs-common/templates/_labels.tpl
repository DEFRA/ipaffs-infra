{{/*
Common labels
*/}}
{{- define "ipaffs-common.labels" -}}
helm.sh/chart: {{ include "deploy.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
defra/environment: "{{ .Values.environment }}"
defra/project: "{{ .Values.project }}"
defra/release-date: "{{ now | date "2006-01-02T15.04.05" }}"
{{ include "ipaffs-common.selectorLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ipaffs-common.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.service }}
app.kubernetes.io/part-of: {{ .Values.project }}
{{- end }}

{{/* vim: set ts=2 sts=2 sw=2 et: */}}
