#!/usr/bin/env bash
# Removes the permanent role assignments that Bicep left behind for roles it now
# grants as PIM eligible. One row per role: Entra access group suffix, role
# definition id, resource type. See PIM-MIGRATION.md.
set -euo pipefail
set -x

roles='
AksAdmin b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b Microsoft.ContainerService/managedClusters
'

fail() {
  echo "##vso[task.logissue type=error]$*"
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

group_id() {
  az ad group show --group "${ENTRA_ACCESS_GROUP_BASE_NAME}-${1}" --query id -o tsv
}

matching_assignments() {
  local principal="$1" role="$2" resource_type="$3"
  local prefix="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP_NAME}/providers/${resource_type}/"
  az role assignment list --all --assignee "${principal}" --role "${role}" --query '[].[id, scope]' -o tsv \
    | awk -v prefix="${prefix,,}" 'index(tolower($2), prefix) == 1 { print $1, $2 }'
}

for name in ENTRA_ACCESS_GROUP_BASE_NAME RESOURCE_GROUP_NAME SUBSCRIPTION_ID DRY_RUN; do
  [[ -n "${!name:-}" ]] || fail "${name} must be set"
done

az account set --subscription "${SUBSCRIPTION_ID}"

while read -r group_suffix role resource_type; do
  [[ -n "${group_suffix}" ]] || continue
  principal="$(group_id "${group_suffix}")"
  mapfile -t assignments < <(matching_assignments "${principal}" "${role}" "${resource_type}")

  if [[ ${#assignments[@]} -eq 0 ]]; then
    log "No permanent assignment of ${role} to ${group_suffix} on ${resource_type}; nothing to do"
    continue
  fi

  for assignment in "${assignments[@]}"; do
    log "Permanent assignment of ${role} to ${group_suffix} on ${assignment#* }"
  done

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY RUN: leaving ${#assignments[@]} assignment(s) in place"
    continue
  fi

  az role assignment delete --ids "${assignments[@]%% *}"
  log "Removed ${#assignments[@]} assignment(s)"
done <<<"${roles}"
