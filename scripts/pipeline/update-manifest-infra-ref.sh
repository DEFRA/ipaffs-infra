#!/bin/bash

set -euo pipefail

: "${MANIFEST_ROOT:?MANIFEST_ROOT is required}"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--check" ) ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

manifest_files=(
  "pipeline.yaml"
  "release-pipeline.yaml"
)

# Validate both entrypoints before updating either. A manifest that owns its
# deployment YAML no longer has an infra pin; a partially migrated manifest must
# still fail rather than silently leaving its remaining pin stale.
resource_state() {
  awk '
    function finish_resource() {
      if (in_infra && refs != 1) invalid = 1
      in_infra = 0
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]*repository:/ {
      finish_resource()
      alias = $0
      sub(/^[[:space:]]*-[[:space:]]*repository:[[:space:]]*/, "", alias)
      sub(/[[:space:]]+#.*$/, "", alias)
      sub(/[[:space:]]*$/, "", alias)
      if (alias ~ /^(ipaffs-infra|"ipaffs-infra"|\047ipaffs-infra\047)$/) {
        aliases++
        in_infra = 1
        refs = 0
        match($0, /^[[:space:]]*/)
        repository_indent = RLENGTH
      } else if (alias == "" || alias ~ /ipaffs-infra/) {
        invalid = 1
      }
      next
    }
    /repository:/ && /ipaffs-infra/ { invalid = 1 }
    in_infra && $0 !~ /^[[:space:]]*(#.*)?$/ {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= repository_indent) {
        finish_resource()
        next
      }
      if ($0 ~ /^[[:space:]]*ref:/) {
        refs++
        value = $0
        sub(/^[[:space:]]*ref:[[:space:]]*/, "", value)
        sub(/[[:space:]]+#.*$/, "", value)
        sub(/[[:space:]]*$/, "", value)
        if (value !~ /^(refs\/[^[:space:]"\047]+|"refs\/[^" ]+"|\047refs\/[^\047 ]+\047)$/) invalid = 1
      }
    }
    END {
      finish_resource()
      if (invalid || aliases > 1) exit 1
      print (aliases == 1 ? "present" : "absent")
    }
  ' "$1"
}

infra_pin_count=0
for manifest_file in "${manifest_files[@]}"; do
  manifest_path="${MANIFEST_ROOT}/${manifest_file}"
  if [[ ! -f "${manifest_path}" ]]; then
    echo "Manifest file not found: ${manifest_path}" >&2
    exit 1
  fi
  if ! state="$(resource_state "${manifest_path}")"; then
    echo "Invalid ipaffs-infra repository resource in ${manifest_path}" >&2
    exit 1
  fi
  if [[ "${state}" == "present" ]]; then
    infra_pin_count=$((infra_pin_count + 1))
  fi
done

if [[ "${infra_pin_count}" -eq 0 ]]; then
  echo "Manifest deployment YAML is independent of ipaffs-infra; no pin update is required"
  echo "##vso[task.setvariable variable=requiresInfraPin;isOutput=true]false"
  exit 0
fi
if [[ "${infra_pin_count}" -ne "${#manifest_files[@]}" ]]; then
  echo "Manifest entrypoints disagree about their ipaffs-infra dependency; refusing a partial pin update" >&2
  exit 1
fi

if [[ "${1:-}" == "--check" ]]; then
  echo "##vso[task.setvariable variable=requiresInfraPin;isOutput=true]true"
  exit 0
fi

: "${INFRA_REF:?INFRA_REF is required}"

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
      if ($0 ~ /^[[:space:]]*-[[:space:]]*repository:/) {
        alias = $0
        sub(/^[[:space:]]*-[[:space:]]*repository:[[:space:]]*/, "", alias)
        sub(/[[:space:]]+#.*$/, "", alias)
        sub(/[[:space:]]*$/, "", alias)
        in_ipaffs_infra_repo = alias ~ /^(ipaffs-infra|"ipaffs-infra"|\047ipaffs-infra\047)$/
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

