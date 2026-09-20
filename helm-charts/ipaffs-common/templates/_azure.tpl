{{/*
Azure Resource Names
*/}}
{{- define "ipaffs-common.azure.databaseName" -}}
{{- $namespaces := list "dev" "tst" "pre" "prd" -}}
{{- if has .Release.Namespace $namespaces -}}
{{- printf "%s" .databaseName -}}
{{- else -}}
{{- printf "%s-%s" .databaseName .Release.Namespace -}}
{{- end -}}
{{- end }}

{{/*
Namespace-scoped identity name prefix, always base-resource-group-derived
regardless of where the identity is actually created.
*/}}
{{- define "ipaffs-common.azure.managedIdentityBaseName" -}}
{{- printf "%s-%s-%s" (include "ipaffs-common.azure.baseResourceGroupK8sName" .) .Release.Namespace .Values.service -}}
{{- end }}

{{- define "ipaffs-common.azure.redisName" -}}
{{- printf "%simpinfrd1401-%s-%s" .Values.environment .Values.service .Release.Namespace }}
{{- end }}

{{/*
True when this release's namespace is this environment's own default
namespace. Any other namespace is an "alternative" namespace and may get its
own dedicated resource group (see resourceGroup below).
*/}}
{{- define "ipaffs-common.azure.isDefaultNamespace" -}}
{{- if eq .Release.Namespace (lower .Values.environment) -}}
true
{{- end -}}
{{- end }}

{{/*
The environment's shared resource group (e.g. "devimpinfrg1401"), threadable
from the pipeline via `.Values.azure.baseResourceGroupName` instead of being
tied exclusively to the hardcoded naming convention.
*/}}
{{- define "ipaffs-common.azure.baseResourceGroup" -}}
{{- if .Values.azure.baseResourceGroupName -}}
{{- printf "%s" .Values.azure.baseResourceGroupName -}}
{{- else -}}
{{- printf "%simpinfrg1401" .Values.environment -}}
{{- end -}}
{{- end }}

{{/*
Lowercase (Kubernetes-safe) forms of the resource group names, for any CR
`metadata.name` or `spec.owner.name` that refers to a resource group.
*/}}
{{- define "ipaffs-common.azure.baseResourceGroupK8sName" -}}
{{- include "ipaffs-common.azure.baseResourceGroup" . | lower -}}
{{- end }}

{{- define "ipaffs-common.azure.resourceGroupK8sName" -}}
{{- include "ipaffs-common.azure.resourceGroup" . | lower -}}
{{- end }}

{{/*
Resource group for namespace-scoped resources. Backwards compatible: absent,
or equal to the base resource group, always resolves to the base resource
group. Only "<baseResourceGroup>-<namespace>" is honoured as a dedicated
group, and only for a non-default namespace; anything else fails the render.
See docs/namespace-resource-groups.md.
*/}}
{{- define "ipaffs-common.azure.resourceGroup" -}}
{{- $base := include "ipaffs-common.azure.baseResourceGroup" . -}}
{{- $override := .Values.azure.namespaceResourceGroupName -}}
{{- if include "ipaffs-common.azure.isDefaultNamespace" . | trim | eq "true" -}}
{{- if and $override (ne (lower $override) (lower $base)) -}}
{{- fail (printf "azure.namespaceResourceGroupName %q must be empty or equal the base resource group %q for the default namespace %q." $override $base .Release.Namespace) -}}
{{- end -}}
{{- printf "%s" $base -}}
{{- else -}}
{{- $dedicated := printf "%s-%s" $base .Release.Namespace -}}
{{- if or (not $override) (eq (lower $override) (lower $base)) -}}
{{- printf "%s" $base -}}
{{- else if eq (lower $override) (lower $dedicated) -}}
{{- printf "%s" $override -}}
{{- else -}}
{{- fail (printf "azure.namespaceResourceGroupName %q is invalid for namespace %q: it must be empty, equal the base resource group %q, or equal the dedicated resource group %q." $override .Release.Namespace $base $dedicated) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "ipaffs-common.azure.serviceBusNamespace" -}}
{{ if .Values.azure.serviceBusNamespace}}
{{- printf "%s" .Values.azure.serviceBusNamespace }}
{{- else -}}
{{- printf "%simpinfsb1401-%s" .Values.environment .Release.Namespace }}
{{- end }}
{{- end }}

{{- define "ipaffs-common.azure.sqlServer" -}}
{{ if .Values.azure.sqlServer}}
{{- printf "%s" .Values.azure.sqlServer }}
{{- else -}}
{{- printf "%simpdbssq1401" .Values.environment }}
{{- end }}
{{- end }}

{{- define "ipaffs-common.azure.sqlServerHostname" -}}
{{ if .Values.azure.sqlServerHostname}}
{{- printf "%s" .Values.azure.sqlServerHostname }}
{{- else -}}
{{- printf "%simpdbssq1401.database.windows.net" .Values.environment }}
{{- end }}
{{- end }}

{{- define "ipaffs-common.azure.searchServiceName" -}}
{{ if .Values.search.serviceName}}
{{- printf "%s" .Values.search.serviceName }}
{{- else -}}
{{- printf "%simpinfas1401" .Values.environment }}
{{- end }}
{{- end }}

{{- define "ipaffs-common.azure.searchServicePrincipalName" -}}
{{ if .Values.search.principalName}}
{{- printf "%s" .Values.search.principalName }}
{{- else -}}
{{- printf "%sIMPINFAS1401" (upper .Values.environment) }}
{{- end }}
{{- end }}

{{/*
Search's resource group. Shared, environment-wide: always falls back to the
base resource group, never the namespace-scoped one.
*/}}
{{- define "ipaffs-common.azure.searchServiceResourceGroupName" -}}
{{ if .Values.search.resourceGroupName}}
{{- printf "%s" .Values.search.resourceGroupName }}
{{- else -}}
{{ template "ipaffs-common.azure.baseResourceGroup" . }}
{{- end }}
{{- end }}

{{/*
The SQL Server's resource group. Defaults to Search's resource group (they
have historically shared one in the classic/higher environments), but can be
overridden independently when SQL and Search do live apart.
*/}}
{{- define "ipaffs-common.azure.sqlServerResourceGroupName" -}}
{{ if .Values.azure.sqlServerResourceGroupName}}
{{- printf "%s" .Values.azure.sqlServerResourceGroupName }}
{{- else -}}
{{ template "ipaffs-common.azure.searchServiceResourceGroupName" . }}
{{- end }}
{{- end }}

{{- define "ipaffs-common.azure.storageAccount" -}}
{{- printf "%simpinfst1401" .Values.environment }}
{{- end }}
