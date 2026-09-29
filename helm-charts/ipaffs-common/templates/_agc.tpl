{{/*
Additive AGC routes over existing ingress hosts. A separate route per FQDN lets
X-Original-Host be set from trusted configuration rather than a caller header.
Callers supply root, hosts (the existing ingress helper output), name, service,
and port. This helper deliberately exposes no arbitrary matches or filters.
*/}}
{{- define "ipaffs-common.agcHttpRoutes" -}}
{{- $root := .root -}}
{{- if $root.Values.agc.enabled -}}
{{- $hosts := list -}}
{{- range (splitList "\n" (trim .hosts)) -}}
  {{- if and (le (len .) 253) (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)+$" .) -}}
    {{- $hosts = append $hosts . -}}
  {{- end -}}
{{- end -}}
{{- $hosts = uniq $hosts -}}
{{- with $root.Values.agc.hosts -}}
  {{- range . -}}
    {{- if not (has . $hosts) -}}
      {{- fail (printf "agc.hosts must contain only existing FQDN ingress hosts; rejected %q" .) -}}
    {{- end -}}
  {{- end -}}
  {{- $hosts = uniq . -}}
{{- end -}}
{{- if gt (len $hosts) 0 -}}
{{- $frontDoorId := required "agc.frontDoorId is required when AGC routes are enabled" $root.Values.agc.frontDoorId -}}
{{- if not (regexMatch "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" $frontDoorId) -}}
  {{- fail "agc.frontDoorId must be a Front Door profile GUID" -}}
{{- end -}}
{{- $gatewayName := required "agc.gateway.name is required when AGC routes are enabled" $root.Values.agc.gateway.name -}}
{{- $gatewayNamespace := required "agc.gateway.namespace is required when AGC routes are enabled" $root.Values.agc.gateway.namespace -}}
{{- $gatewaySection := required "agc.gateway.sectionName is required when AGC routes are enabled" $root.Values.agc.gateway.sectionName -}}
{{- $routeName := .name -}}
{{- $service := .service -}}
{{- $port := .port -}}
{{- range $host := $hosts }}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ printf "%s-agc-%s" ($routeName | trunc 40 | trimSuffix "-") (sha256sum $host | trunc 12) }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "ipaffs-common.labels" $root | nindent 4 }}
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: {{ $gatewayName | quote }}
      namespace: {{ $gatewayNamespace | quote }}
      sectionName: {{ $gatewaySection | quote }}
  hostnames:
    - {{ $host | quote }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
          headers:
            - type: Exact
              name: X-Azure-FDID
              value: {{ $frontDoorId | quote }}
      {{- with $root.Values.agc.requestTimeout }}
      timeouts:
        request: {{ . | quote }}
      {{- end }}
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: X-Original-Host
                value: {{ $host | quote }}
      backendRefs:
        - group: ""
          kind: Service
          name: {{ $service }}
          port: {{ $port }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
