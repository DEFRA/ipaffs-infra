#!/bin/bash

set -euo pipefail

: "${MANIFEST_ROOT:?MANIFEST_ROOT is required}"
: "${INFRA_REF:?INFRA_REF is required}"

manifest_files=(
  "pipeline.yaml"
  "release-pipeline.yaml"
)

update_manifest_file() {
  local manifest_file="$1"
  local tmp_file=""

  if [[ ! -f "${manifest_file}" ]]; then
    echo "Manifest file not found: ${manifest_file}" >&2
    exit 1
  fi

  tmp_file="$(mktemp)"

  if ! awk -v infra_ref="${INFRA_REF}" '
    BEGIN {
      in_ipaffs_infra_repo = 0
      updated = 0
    }
    {
      if ($0 ~ /^[[:space:]]*-[[:space:]]*repository:[[:space:]]*ipaffs-infra[[:space:]]*$/) {
        in_ipaffs_infra_repo = 1
        print
        next
      }

      if (in_ipaffs_infra_repo && $0 ~ /^[[:space:]]*ref:[[:space:]]+/) {
        sub(/ref:[[:space:]]+.*/, "ref: " infra_ref)
        print
        updated++
        in_ipaffs_infra_repo = 0
        next
      }

      if (in_ipaffs_infra_repo && $0 ~ /^[[:space:]]*-[[:space:]]*repository:[[:space:]]*/) {
        in_ipaffs_infra_repo = 0
      }

      print
    }
    END {
      if (updated == 0) {
        exit 1
      }
    }
  ' "${manifest_file}" >"${tmp_file}"; then
    rm -f "${tmp_file}"
    echo "Unable to update ipaffs-infra ref in ${manifest_file}" >&2
    exit 1
  fi

  mv "${tmp_file}" "${manifest_file}"
}

for manifest_file in "${manifest_files[@]}"; do
  update_manifest_file "${MANIFEST_ROOT}/${manifest_file}"
done

# vim: set ts=2 sts=2 sw=2 et:
