{{/*
Render resource requirements without CPU limits, regardless of service values.
Copy first so filtering does not mutate values used by other templates.
*/}}
{{- define "ipaffs-common.resources" -}}
{{- $resources := deepCopy (. | default dict) -}}
{{- if hasKey $resources "limits" -}}
  {{- $limits := omit (get $resources "limits" | default dict) "cpu" -}}
  {{- if $limits -}}
    {{- $_ := set $resources "limits" $limits -}}
  {{- else -}}
    {{- $_ := unset $resources "limits" -}}
  {{- end -}}
{{- end -}}
{{- with $resources -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}
