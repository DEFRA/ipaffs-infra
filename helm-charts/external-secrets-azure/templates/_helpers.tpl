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

{{/*
Render the Azure Key Vault provider block for a ClusterSecretStore.
Input:
  root: chart root context
  azure: store values object
  path: values path string for validation errors
*/}}
{{- define "external-secrets-azure.azurekvProvider" -}}
{{- $root := .root -}}
{{- $azure := default dict .azure -}}
{{- $path := .path -}}
{{- $authType := default "WorkloadIdentity" $azure.authType -}}
{{- $sa := default dict $azure.serviceAccountRef -}}
{{- $sp := default dict $azure.servicePrincipal -}}
provider:
  azurekv:
    vaultUrl: {{ required (printf "%s.vaultUrl is required" $path) $azure.vaultUrl | quote }}
    tenantId: {{ required (printf "%s.tenantId is required" $path) $azure.tenantId | quote }}
    authType: {{ $authType | quote }}
    {{- if eq $authType "WorkloadIdentity" }}
    identityId: {{ required (printf "%s.identityId is required when authType is WorkloadIdentity" $path) $azure.identityId | quote }}
    serviceAccountRef:
      name: {{ required (printf "%s.serviceAccountRef.name is required when authType is WorkloadIdentity" $path) (default "external-secrets" $sa.name) | quote }}
      namespace: {{ required (printf "%s.serviceAccountRef.namespace is required when authType is WorkloadIdentity" $path) (default $root.Release.Namespace $sa.namespace) | quote }}
    {{- else if eq $authType "ManagedIdentity" }}
    identityId: {{ required (printf "%s.identityId is required when authType is ManagedIdentity" $path) $azure.identityId | quote }}
    {{- else if eq $authType "ServicePrincipal" }}
    clientId: {{ required (printf "%s.servicePrincipal.clientId is required when authType is ServicePrincipal" $path) $sp.clientId | quote }}
    clientSecretSecretRef:
      name: {{ required (printf "%s.servicePrincipal.secretName is required when authType is ServicePrincipal" $path) $sp.secretName | quote }}
      key: {{ required (printf "%s.servicePrincipal.clientSecretKey is required when authType is ServicePrincipal" $path) $sp.clientSecretKey | quote }}
      namespace: {{ default $root.Release.Namespace $sp.secretNamespace | quote }}
    {{- end }}
{{- end -}}

{{/*
Render a ServicePrincipal auth secret when configured for a store.
Input:
  root: chart root context
  azure: store values object
  path: values path string for validation errors
*/}}
{{- define "external-secrets-azure.servicePrincipalSecret" -}}
{{- $root := .root -}}
{{- $azure := default dict .azure -}}
{{- $path := .path -}}
{{- $authType := default "WorkloadIdentity" $azure.authType -}}
{{- $sp := default dict $azure.servicePrincipal -}}
{{- if and (eq $authType "ServicePrincipal") $sp.createSecret }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ required (printf "%s.servicePrincipal.secretName is required when creating a service principal secret" $path) $sp.secretName | quote }}
  namespace: {{ default $root.Release.Namespace $sp.secretNamespace | quote }}
type: Opaque
stringData:
  {{ required (printf "%s.servicePrincipal.clientIdKey is required when creating a service principal secret" $path) $sp.clientIdKey }}: {{ required (printf "%s.servicePrincipal.clientId is required when creating a service principal secret" $path) $sp.clientId | quote }}
  {{ required (printf "%s.servicePrincipal.clientSecretKey is required when creating a service principal secret" $path) $sp.clientSecretKey }}: {{ required (printf "%s.servicePrincipal.clientSecret is required when creating a service principal secret" $path) $sp.clientSecret | quote }}
{{- end }}
{{- end -}}
