{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "deploy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "deploy.labels" -}}
helm.sh/chart: {{ include "deploy.chart" . }}
{{ include "deploy.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "deploy.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/part-of: {{ .Values.project }}
{{- end }}

{{/*
Ingress hosts
*/}}
{{- define "deploy.ingressHosts" -}}
  {{- $hosts := list -}}
  {{- range .Values.ingress.hosts }}
    {{- $host := printf "%s.imp.%s.azure.defra.cloud" . $.Values.environment -}}
    {{- $hosts = append $hosts $host }}
  {{- end -}}
  {{- $hosts | join "\n" -}}
{{- end }}