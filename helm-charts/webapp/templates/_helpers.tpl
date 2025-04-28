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
  {{- if gt (len .Values.ingress.hosts) 0 -}}
    {{- $hosts := list -}}
    {{- range .Values.ingress.hosts }}
      {{- $host := $.Values.environment -}}
      {{- $hostWithSuffix := printf "%s.imp.%s.azure.defra.cloud" . $host -}}
      {{- $hosts = append $hosts $host  }}
      {{- $hosts = append $hosts $hostWithSuffix }}
    {{- end -}}
    {{- $hosts | join "\n" -}}
  {{- end -}}
{{- end }}
