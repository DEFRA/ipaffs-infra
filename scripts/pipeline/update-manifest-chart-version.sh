#!/bin/bash

set -euo pipefail

: "${CHART_NAME:?CHART_NAME is required}"
: "${CHART_VERSION:?CHART_VERSION is required}"
: "${MANIFEST_ROOT:?MANIFEST_ROOT is required}"

helmfile_path="${MANIFEST_ROOT}/helmfile.yaml.gotmpl"

if [[ ! -f "${helmfile_path}" ]]; then
  echo "Helmfile not found: ${helmfile_path}" >&2
  exit 1
fi

tmp_file="$(mktemp)"

if ! awk -v chart="$CHART_NAME" -v version="$CHART_VERSION" '
  BEGIN {
    in_target_chart_block = 0
    updated = 0
  }
  {
    if ($0 ~ "^[[:space:]]*chart:[[:space:]]+acr/helm/v1/repo/" chart "$") {
      in_target_chart_block = 1
      print
      next
    }

    if (in_target_chart_block && $0 ~ "^[[:space:]]*version:[[:space:]]+") {
      print "    version: " version
      in_target_chart_block = 0
      updated++
      next
    }

    if (in_target_chart_block && $0 ~ "^[[:space:]]*chart:[[:space:]]+") {
      in_target_chart_block = 0
    }

    print
  }
  END {
    if (updated == 0) {
      exit 1
    }
  }
' "${helmfile_path}" > "${tmp_file}"; then
  rm -f "${tmp_file}"
  echo "Failed to update chart version for '${CHART_NAME}' in ${helmfile_path}" >&2
  exit 1
fi

mv "${tmp_file}" "${helmfile_path}"

# vim: set ts=2 sts=2 sw=2 et:
