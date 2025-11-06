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
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: {{ .Values.project }}
{{- end }}

{{/*
Ingress hosts
*/}}
{{- define "deploy.ingressHosts" -}}
  {{- if gt (len .Values.ingress.hosts) 0 -}}
    {{- $hosts := list -}}
    {{- range .Values.ingress.hosts }}
      {{- $host := . -}}
      {{- $hostWithSuffix := printf "%s-%s.imp.%s.azure.defra.cloud" $host $.Values.environment $.Values.environment -}}
      {{- $hosts = append $hosts $host }}
      {{- $hosts = append $hosts $hostWithSuffix }}
    {{- end -}}
    {{- $hosts | join "\n" -}}
  {{- end -}}
{{- end }}

{{/*
Azure Resource Names
*/}}
{{- define "deploy.azure.databaseName" -}}
{{- printf "%s-%s" .Release.Name .Release.Namespace }}
{{- end }}
{{- define "deploy.azure.managedIdentityBaseName" -}}
{{- printf "%simpinfsb1401" .Values.environment .Release.Namespace }}
{{- end }}
{{- define "deploy.azure.redisName" -}}
{{- printf "%simpinfrd1401-%s" .Values.environment .Release.Namespace }}
{{- end }}
{{- define "deploy.azure.resourceGroup" -}}
{{- printf "%simpinfsb1401-%s" .Values.environment .Release.Namespace }}
{{- end }}
{{- define "deploy.azure.serviceBusNamespace" -}}
{{- printf "%simpinfsb1401-%s" .Values.environment .Release.Namespace }}
{{- end }}
{{- define "deploy.azure.sqlServer" -}}
{{- printf "%simpdbssq1401" .Values.environment }}
{{- end }}
