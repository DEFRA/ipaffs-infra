{{/* Application filesystem policy is chart-owned and cannot be weakened by values. */}}
{{- define "ipaffs-common.filesystem.podSpec" -}}
securityContext:
  fsGroup: 1000
volumes:
  - name: temporary-files
    emptyDir: {}
{{- end -}}

{{- define "ipaffs-common.filesystem.applicationSecurity" -}}
{{- $context := omit (.Values.container.securityContext | default dict) "readOnlyRootFilesystem" -}}
{{- $_ := set $context "readOnlyRootFilesystem" true -}}
securityContext:
  {{- $context | toYaml | nindent 2 }}
volumeMounts:
  - name: temporary-files
    mountPath: /tmp
    readOnly: false
{{- end -}}

{{- define "ipaffs-common.filesystem.diagnosticsEnv" -}}
- name: APPLICATIONINSIGHTS_SELF_DIAGNOSTICS_FILE_PATH
  value: /tmp/applicationinsights.log
{{- end -}}
