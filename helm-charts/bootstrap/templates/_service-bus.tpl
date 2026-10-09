{{/*
Keep Azure names containing underscores distinct from the old hyphenated entities.
ASO does not allow an existing resource's Azure name to change in place.
*/}}
{{- define "bootstrap.serviceBus.resourceName" -}}
{{- if contains "_" . -}}
{{- printf "%s-%s" (replace "_" "-" .) (sha256sum . | trunc 8) -}}
{{- else -}}
{{- . -}}
{{- end -}}
{{- end -}}
