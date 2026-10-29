#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: snd-app-services.sh <action>

Actions:
  disable  Record the original plan size as tags, turn autoscale off, stop
           all apps and slots, turn off File Change Audit logs that need a
           Premium plan, then scale each plan to B1 (S1 when it hosts slots).
  restore  Undo disable on plans tagged by it. Scale each plan back to its
           original size, turn File Change Audit logs and autoscale back on,
           start only the apps and slots disable stopped, then remove the tags.
  delete   List the slots, apps and plans that would be deleted.
           Always a dry run until DELETE_ENABLED is changed in this script.

A delete run adds a CanNotDelete lock named ipaffs-pipeline-run to every listed
resource group before listing, and removes it when the run ends. Disable and
restore add no lock.

Environment:
  SUBSCRIPTION_NAME  Must be AZR-SND.
  TARGETS_FILE       Resource group allowlist; defaults to snd-app-services-targets.txt.
  DRY_RUN            true or false for disable and restore; defaults to true.
USAGE
}

# Delete stays a dry run until this is changed in a reviewed pull request
readonly DELETE_ENABLED=false

readonly EXPECTED_SUBSCRIPTION="AZR-SND"
readonly RESOURCE_GROUP_PREFIX="SNDIMP"
readonly TAG_ORIGINAL_SKU="ipaffs-original-sku"
readonly TAG_ORIGINAL_CAPACITY="ipaffs-original-capacity"
readonly TAG_AUTOSCALE_OFF="ipaffs-autoscale-off"
readonly TAG_DISABLED="ipaffs-disabled"
readonly TAG_STOPPED="ipaffs-stopped-by-pipeline"

# File change audit logs need a Premium plan so they are turned off before scaling down
readonly PREMIUM_LOG_CATEGORY="AppServiceFileAuditLogs"
readonly TAG_FILE_AUDIT_OFF="ipaffs-file-audit-off"

# A delete run locks its resource groups against deletion and unlocks them at the end
readonly RUN_LOCK_NAME="ipaffs-pipeline-run"
readonly RUN_LOCK_NOTES="Added by the SND App Services pipeline for the duration of a run"

LOCKED_GROUPS=""

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

error() {
  echo "ERROR: $*" >&2
}

fail() {
  error "$@"
  exit 1
}

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

lowercase() {
  tr '[:upper:]' '[:lower:]' <<<"${1}"
}

normalise_bool() {
  case "$(lowercase "${1:-true}")" in
    1|true|yes|y|on)
      echo true
      ;;
    0|false|no|n|off)
      echo false
      ;;
    *)
      fail "DRY_RUN must be true or false; got '${1}'"
      ;;
  esac
}

print_command() {
  printf "%q " "$@"
  printf "\n"
}

print_dry_run() {
  printf "DRY RUN: "
  print_command "$@"
}

run_cmd() {
  if [[ "${DRY_RUN_ENABLED}" == "true" ]]; then
    print_dry_run "$@"
    return 0
  fi

  "$@"
}

# Only prints unless deletion has been enabled in code
run_delete_cmd() {
  if [[ "${REAL_DELETE}" != "true" ]]; then
    print_dry_run "$@"
    return 0
  fi

  "$@"
}

read_targets() {
  local line

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -n "${line}" ]]; then
      echo "${line}"
    fi
  done <"${TARGETS_FILE}"
}

validate_resource_group() {
  local resource_group="${1}"
  local blocking_locks

  [[ "${resource_group}" == "${RESOURCE_GROUP_PREFIX}"* ]] \
    || fail "Resource group '${resource_group}' does not start with '${RESOURCE_GROUP_PREFIX}'"

  az group show --subscription "${SUBSCRIPTION_NAME}" --name "${resource_group}" --output none >/dev/null 2>&1 \
    || fail "Resource group '${resource_group}' was not found in subscription '${SUBSCRIPTION_NAME}'"

  # ReadOnly blocks stop and scale and real deletion is blocked by any lock
  blocking_locks="$(az lock list \
    --subscription "${SUBSCRIPTION_NAME}" \
    --resource-group "${resource_group}" \
    --query "[].{name:name, level:level}" \
    --output json \
    | jq -r --argjson any "${REAL_DELETE}" '[.[] | select($any or .level == "ReadOnly") | .name] | join(", ")')"
  [[ -z "${blocking_locks}" ]] \
    || fail "Resource group '${resource_group}' has blocking lock(s) ${blocking_locks}"
}

# Creating the lock again over one left by a killed run is harmless
lock_resource_groups() {
  local resource_group

  [[ "${LOCK_MODE}" != "none" ]] || return 0

  while IFS= read -r resource_group; do
    log "Locking resource group '${resource_group}' with CanNotDelete lock '${RUN_LOCK_NAME}'"
    az lock create \
      --subscription "${SUBSCRIPTION_NAME}" \
      --resource-group "${resource_group}" \
      --name "${RUN_LOCK_NAME}" \
      --lock-type CanNotDelete \
      --notes "${RUN_LOCK_NOTES}" \
      --output none
    LOCKED_GROUPS+="${resource_group}"$'\n'
  done <<<"${1}"
}

# Removes only the run lock, even when the run fails
unlock_resource_groups() {
  local status=$?
  local resource_group

  trap - EXIT
  set +e

  while IFS= read -r resource_group; do
    [[ -n "${resource_group}" ]] || continue
    log "Removing lock '${RUN_LOCK_NAME}' from resource group '${resource_group}'"
    if ! az lock delete \
      --subscription "${SUBSCRIPTION_NAME}" \
      --resource-group "${resource_group}" \
      --name "${RUN_LOCK_NAME}" \
      --output none; then
      error "Could not remove lock '${RUN_LOCK_NAME}' from resource group '${resource_group}'; remove it manually"
      [[ "${status}" -ne 0 ]] || status=1
    fi
  done <<<"${LOCKED_GROUPS}"

  exit "${status}"
}

load_autoscale_settings() {
  local resource_groups resource_group settings

  resource_groups="$(az resource list \
    --subscription "${SUBSCRIPTION_NAME}" \
    --resource-type "Microsoft.Insights/autoscalesettings" \
    --query "[].resourceGroup" \
    --output tsv | sort -fu)"

  AUTOSCALE_JSON='[]'
  while IFS= read -r resource_group; do
    [[ -n "${resource_group}" ]] || continue
    settings="$(az monitor autoscale list \
      --subscription "${SUBSCRIPTION_NAME}" \
      --resource-group "${resource_group}" \
      --query "[].{name:name, resourceGroup:resourceGroup, enabled:enabled, target:targetResourceUri}" \
      --output json)"
    AUTOSCALE_JSON="$(jq -c --argjson more "${settings}" '. + $more' <<<"${AUTOSCALE_JSON}")"
  done <<<"${resource_groups}"
}

list_sites() {
  local resource_group="${1}"
  local query="[].{id:id, name:name, kind:kind, state:state, plan:appServicePlanId, tags:tags}"
  local web_apps function_apps

  web_apps="$(az webapp list --subscription "${SUBSCRIPTION_NAME}" --resource-group "${resource_group}" --query "${query}" --output json)"
  function_apps="$(az functionapp list --subscription "${SUBSCRIPTION_NAME}" --resource-group "${resource_group}" --query "${query}" --output json)"

  jq -cn --argjson web "${web_apps}" --argjson func "${function_apps}" \
    '$web + $func | unique_by(.id | ascii_downcase)'
}

list_slot_ids() {
  local resource_group="${1}"

  az resource list \
    --subscription "${SUBSCRIPTION_NAME}" \
    --resource-group "${resource_group}" \
    --resource-type "Microsoft.Web/sites/slots" \
    --query "[].id" \
    --output tsv
}

sites_on_plan() {
  local plan_id="${1}"
  local sites_json="${2}"

  jq -c --arg plan "$(lowercase "${plan_id}")" \
    '.[] | select((.plan // "" | ascii_downcase) == $plan)' <<<"${sites_json}"
}

slots_for_site() {
  local site_id="${1}"
  local slot_ids="${2}"

  awk -v prefix="$(lowercase "${site_id}")/slots/" 'index(tolower($0), prefix) == 1' <<<"${slot_ids}"
}

app_cli_for_kind() {
  if [[ "$(lowercase "${1}")" == *functionapp* ]]; then
    echo functionapp
  else
    echo webapp
  fi
}

resource_tag() {
  az tag list --resource-id "${1}" --query "properties.tags.\"${2}\"" --output tsv
}

# Marks an app or slot so restore starts only what disable stopped
stop_resource() {
  local app_cli="${1}"
  local resource_id="${2}"

  run_cmd az tag update \
    --resource-id "${resource_id}" \
    --operation Merge \
    --tags "${TAG_STOPPED}=$(date -u +"%Y-%m-%d")" \
    --output none
  run_cmd az "${app_cli}" stop --ids "${resource_id}"
}

# Tags the app with the settings it changes so a rerun keeps the full list
disable_premium_logs() {
  local resource_id="${1}"
  local recorded="${2}"
  local settings setting_name log_index

  settings="$(az monitor diagnostic-settings list --resource "${resource_id}" --output json \
    | jq -r --arg category "${PREMIUM_LOG_CATEGORY}" \
      '.[] | .name as $name | .logs | to_entries[] | select(.value.category == $category and .value.enabled) | [$name, .key] | @tsv')"
  [[ -n "${settings}" ]] || return 0

  run_cmd az tag update \
    --resource-id "${resource_id}" \
    --operation Merge \
    --tags "${TAG_FILE_AUDIT_OFF}=$( { tr ',' '\n' <<<"${recorded}"; cut -f1 <<<"${settings}"; } | grep -v '^$' | sort -u | paste -sd, -)" \
    --output none

  while IFS=$'\t' read -r setting_name log_index; do
    log "Turning off ${PREMIUM_LOG_CATEGORY} in diagnostic setting '${setting_name}' on '${resource_id##*/sites/}'"
    run_cmd az monitor diagnostic-settings update \
      --resource "${resource_id}" \
      --name "${setting_name}" \
      --set "logs[${log_index}].enabled=false" \
      --output none
  done <<<"${settings}"
}

disable_plan() {
  local plan_json="${1}"
  local sites_json="${2}"
  local slot_ids="${3}"
  local plan_id plan_name sku capacity disabled_tag plan_sites plan_slots target_sku
  local autoscale_enabled autoscale_off autoscale_name autoscale_group site_json site_id site_name site_kind site_state slot_id app_cli

  plan_id="$(jq -r '.id' <<<"${plan_json}")"
  plan_name="$(jq -r '.name' <<<"${plan_json}")"
  sku="$(jq -r '.sku' <<<"${plan_json}")"
  capacity="$(jq -r '.capacity' <<<"${plan_json}")"
  disabled_tag="$(jq -r --arg tag "${TAG_DISABLED}" '.tags[$tag] // empty' <<<"${plan_json}")"

  plan_sites="$(sites_on_plan "${plan_id}" "${sites_json}")"
  plan_slots=""
  while IFS= read -r site_json; do
    [[ -n "${site_json}" ]] || continue
    plan_slots+="$(slots_for_site "$(jq -r '.id' <<<"${site_json}")" "${slot_ids}")"$'\n'
  done <<<"${plan_sites}"
  plan_slots="$(grep -v '^$' <<<"${plan_slots}" || true)"

  # Basic plans do not support slots so those plans use Standard
  target_sku="B1"
  [[ -z "${plan_slots}" ]] || target_sku="S1"

  autoscale_off="$(jq -r --arg plan "$(lowercase "${plan_id}")" \
    '[.[] | select((.target // "" | ascii_downcase) == $plan and .enabled == true) | "\(.resourceGroup)/\(.name)"] | join(",")' \
    <<<"${AUTOSCALE_JSON}")"
  autoscale_enabled=false
  [[ -z "${autoscale_off}" ]] || autoscale_enabled=true

  log "Disabling plan '${plan_name}' (${sku} x${capacity}, autoscale ${autoscale_enabled}) to ${target_sku} x1"

  # Record the original size once so a rerun never overwrites it
  if [[ -z "${disabled_tag}" ]]; then
    run_cmd az tag update \
      --resource-id "${plan_id}" \
      --operation Merge \
      --tags \
        "${TAG_ORIGINAL_SKU}=${sku}" \
        "${TAG_ORIGINAL_CAPACITY}=${capacity}" \
        "${TAG_AUTOSCALE_OFF}=${autoscale_off:-none}" \
        "${TAG_DISABLED}=$(date -u +"%Y-%m-%d")" \
      --output none
  else
    log "Plan '${plan_name}' was already disabled on ${disabled_tag}, keeping its original tags"
  fi

  # Autoscale would scale the plan back up so it goes first
  while IFS=$'\t' read -r autoscale_name autoscale_group; do
    [[ -n "${autoscale_name}" ]] || continue
    log "Turning off autoscale setting '${autoscale_name}'"
    run_cmd az monitor autoscale update \
      --subscription "${SUBSCRIPTION_NAME}" \
      --resource-group "${autoscale_group}" \
      --name "${autoscale_name}" \
      --enabled false \
      --output none
  done < <(jq -r --arg plan "$(lowercase "${plan_id}")" \
    '.[] | select((.target // "" | ascii_downcase) == $plan and .enabled == true) | [.name, .resourceGroup] | @tsv' \
    <<<"${AUTOSCALE_JSON}")

  while IFS= read -r site_json; do
    [[ -n "${site_json}" ]] || continue
    site_id="$(jq -r '.id' <<<"${site_json}")"
    site_name="$(jq -r '.name' <<<"${site_json}")"
    site_kind="$(jq -r '.kind // ""' <<<"${site_json}")"
    site_state="$(jq -r '.state // ""' <<<"${site_json}")"
    app_cli="$(app_cli_for_kind "${site_kind}")"

    while IFS= read -r slot_id; do
      [[ -n "${slot_id}" ]] || continue
      log "Stopping slot '${slot_id##*/sites/}'"
      stop_resource "${app_cli}" "${slot_id}"
    done < <(slots_for_site "${site_id}" "${slot_ids}")

    if [[ "$(lowercase "${site_state}")" == "stopped" ]]; then
      log "App '${site_name}' is already stopped"
    else
      log "Stopping ${app_cli} '${site_name}'"
      stop_resource "${app_cli}" "${site_id}"
    fi
  done <<<"${plan_sites}"

  if [[ "${sku}" == "${target_sku}" && "${capacity}" == "1" ]]; then
    log "Plan '${plan_name}' is already ${target_sku} x1"
  else
    while IFS= read -r site_json; do
      [[ -n "${site_json}" ]] || continue
      disable_premium_logs "$(jq -r '.id' <<<"${site_json}")" \
        "$(jq -r --arg tag "${TAG_FILE_AUDIT_OFF}" '.tags[$tag] // ""' <<<"${site_json}")"
    done <<<"${plan_sites}"
    while IFS= read -r slot_id; do
      [[ -n "${slot_id}" ]] || continue
      disable_premium_logs "${slot_id}" ""
    done <<<"${plan_slots}"

    run_cmd az appservice plan update \
      --ids "${plan_id}" \
      --sku "${target_sku}" \
      --number-of-workers 1 \
      --output none
  fi
}

# Turns the audit category back on in the settings disable recorded
restore_premium_logs() {
  local resource_id="${1}"
  local recorded="${2}"
  local setting_name log_index

  [[ -n "${recorded}" ]] || return 0

  while IFS= read -r setting_name; do
    [[ -n "${setting_name}" ]] || continue
    log_index="$(az monitor diagnostic-settings show --resource "${resource_id}" --name "${setting_name}" --output json \
      | jq -r --arg category "${PREMIUM_LOG_CATEGORY}" '.logs | map(.category) | index($category) // empty')"
    if [[ -z "${log_index}" ]]; then
      log "WARNING: diagnostic setting '${setting_name}' on '${resource_id##*/sites/}' has no ${PREMIUM_LOG_CATEGORY}"
      continue
    fi
    log "Turning on ${PREMIUM_LOG_CATEGORY} in diagnostic setting '${setting_name}' on '${resource_id##*/sites/}'"
    run_cmd az monitor diagnostic-settings update \
      --resource "${resource_id}" \
      --name "${setting_name}" \
      --set "logs[${log_index}].enabled=true" \
      --output none
  done < <(tr ',' '\n' <<<"${recorded}")

  run_cmd az tag update --resource-id "${resource_id}" --operation Delete --tags "${TAG_FILE_AUDIT_OFF}" --output none
}

# Starts an app or slot only when disable stopped it
restore_resource() {
  local app_cli="${1}"
  local resource_id="${2}"
  local stopped="${3}"
  local recorded_logs="${4}"

  restore_premium_logs "${resource_id}" "${recorded_logs}"

  [[ -n "${stopped}" ]] || return 0
  log "Starting ${app_cli} '${resource_id##*/sites/}'"
  run_cmd az "${app_cli}" start --ids "${resource_id}"
  run_cmd az tag update --resource-id "${resource_id}" --operation Delete --tags "${TAG_STOPPED}" --output none
}

restore_plan() {
  local plan_json="${1}"
  local sites_json="${2}"
  local slot_ids="${3}"
  local plan_id plan_name sku capacity disabled_tag original_sku original_capacity autoscale_off
  local autoscale autoscale_name autoscale_group plan_sites site_json site_id app_cli slot_id

  plan_id="$(jq -r '.id' <<<"${plan_json}")"
  plan_name="$(jq -r '.name' <<<"${plan_json}")"
  sku="$(jq -r '.sku' <<<"${plan_json}")"
  capacity="$(jq -r '.capacity' <<<"${plan_json}")"
  disabled_tag="$(jq -r --arg tag "${TAG_DISABLED}" '.tags[$tag] // empty' <<<"${plan_json}")"

  if [[ -z "${disabled_tag}" ]]; then
    log "Plan '${plan_name}' was not disabled by this pipeline, leaving it alone"
    return 0
  fi

  original_sku="$(jq -r --arg tag "${TAG_ORIGINAL_SKU}" '.tags[$tag] // empty' <<<"${plan_json}")"
  original_capacity="$(jq -r --arg tag "${TAG_ORIGINAL_CAPACITY}" '.tags[$tag] // empty' <<<"${plan_json}")"
  autoscale_off="$(jq -r --arg tag "${TAG_AUTOSCALE_OFF}" '.tags[$tag] // "none"' <<<"${plan_json}")"
  [[ -n "${original_sku}" && -n "${original_capacity}" ]] \
    || fail "Plan '${plan_name}' is missing ${TAG_ORIGINAL_SKU} or ${TAG_ORIGINAL_CAPACITY}"

  log "Restoring plan '${plan_name}' (${sku} x${capacity}) to ${original_sku} x${original_capacity}, disabled on ${disabled_tag}"

  # Audit logs need the Premium plan back first
  if [[ "${sku}" == "${original_sku}" && "${capacity}" == "${original_capacity}" ]]; then
    log "Plan '${plan_name}' is already ${original_sku} x${original_capacity}"
  else
    run_cmd az appservice plan update \
      --ids "${plan_id}" \
      --sku "${original_sku}" \
      --number-of-workers "${original_capacity}" \
      --output none
  fi

  if [[ "${autoscale_off}" != "none" ]]; then
    while IFS= read -r autoscale; do
      [[ -n "${autoscale}" ]] || continue
      autoscale_group="${autoscale%%/*}"
      autoscale_name="${autoscale#*/}"
      log "Turning on autoscale setting '${autoscale_name}'"
      run_cmd az monitor autoscale update \
        --subscription "${SUBSCRIPTION_NAME}" \
        --resource-group "${autoscale_group}" \
        --name "${autoscale_name}" \
        --enabled true \
        --output none
    done < <(tr ',' '\n' <<<"${autoscale_off}")
  fi

  plan_sites="$(sites_on_plan "${plan_id}" "${sites_json}")"
  while IFS= read -r site_json; do
    [[ -n "${site_json}" ]] || continue
    site_id="$(jq -r '.id' <<<"${site_json}")"
    app_cli="$(app_cli_for_kind "$(jq -r '.kind // ""' <<<"${site_json}")")"

    # Slot tags are not in the app listing so they are read one by one
    while IFS= read -r slot_id; do
      [[ -n "${slot_id}" ]] || continue
      restore_resource "${app_cli}" "${slot_id}" \
        "$(resource_tag "${slot_id}" "${TAG_STOPPED}")" "$(resource_tag "${slot_id}" "${TAG_FILE_AUDIT_OFF}")"
    done < <(slots_for_site "${site_id}" "${slot_ids}")

    restore_resource "${app_cli}" "${site_id}" \
      "$(jq -r --arg tag "${TAG_STOPPED}" '.tags[$tag] // ""' <<<"${site_json}")" \
      "$(jq -r --arg tag "${TAG_FILE_AUDIT_OFF}" '.tags[$tag] // ""' <<<"${site_json}")"
  done <<<"${plan_sites}"

  # The plan tags go last so a failed restore can be rerun
  run_cmd az tag update \
    --resource-id "${plan_id}" \
    --operation Delete \
    --tags "${TAG_ORIGINAL_SKU}" "${TAG_ORIGINAL_CAPACITY}" "${TAG_AUTOSCALE_OFF}" "${TAG_DISABLED}" \
    --output none
}

delete_plan() {
  local plan_json="${1}"
  local sites_json="${2}"
  local slot_ids="${3}"
  local plan_id plan_name disabled_tag plan_sites site_json site_id site_name site_kind slot_id app_cli resource_group

  plan_id="$(jq -r '.id' <<<"${plan_json}")"
  plan_name="$(jq -r '.name' <<<"${plan_json}")"
  disabled_tag="$(jq -r --arg tag "${TAG_DISABLED}" '.tags[$tag] // empty' <<<"${plan_json}")"
  resource_group="$(jq -r '.resourceGroup' <<<"${plan_json}")"

  # Only plans that went through disable may be deleted
  if [[ -z "${disabled_tag}" ]]; then
    [[ "${REAL_DELETE}" != "true" ]] || fail "Plan '${plan_name}' has not been disabled; run disable first"
    log "WARNING: plan '${plan_name}' has not been disabled yet and would be refused"
  fi

  log "Deleting plan '${plan_name}' and its apps"
  plan_sites="$(sites_on_plan "${plan_id}" "${sites_json}")"

  while IFS= read -r site_json; do
    [[ -n "${site_json}" ]] || continue
    site_id="$(jq -r '.id' <<<"${site_json}")"
    site_name="$(jq -r '.name' <<<"${site_json}")"
    site_kind="$(jq -r '.kind // ""' <<<"${site_json}")"
    app_cli="$(app_cli_for_kind "${site_kind}")"

    while IFS= read -r slot_id; do
      [[ -n "${slot_id}" ]] || continue
      run_delete_cmd az "${app_cli}" deployment slot delete \
        --subscription "${SUBSCRIPTION_NAME}" \
        --resource-group "${resource_group}" \
        --name "${site_name}" \
        --slot "${slot_id##*/}"
    done < <(slots_for_site "${site_id}" "${slot_ids}")

    if [[ "${app_cli}" == "webapp" ]]; then
      run_delete_cmd az webapp delete --ids "${site_id}" --keep-empty-plan
    else
      run_delete_cmd az functionapp delete --ids "${site_id}"
    fi
  done <<<"${plan_sites}"

  run_delete_cmd az appservice plan delete --ids "${plan_id}" --yes
}

process_resource_group() {
  local resource_group="${1}"
  local plans_json sites_json slot_ids plan_json

  log "Resource group '${resource_group}'"

  plans_json="$(az appservice plan list \
    --subscription "${SUBSCRIPTION_NAME}" \
    --resource-group "${resource_group}" \
    --query "[].{id:id, name:name, resourceGroup:resourceGroup, sku:sku.name, capacity:sku.capacity, tags:tags}" \
    --output json)"
  sites_json="$(list_sites "${resource_group}")"
  slot_ids="$(list_slot_ids "${resource_group}")"

  log "Found $(jq 'length' <<<"${plans_json}") plan(s), $(jq 'length' <<<"${sites_json}") app(s) and $(grep -c . <<<"${slot_ids}" || true) slot(s)"

  while IFS= read -r plan_json; do
    [[ -n "${plan_json}" ]] || continue
    case "${ACTION}" in
      disable)
        disable_plan "${plan_json}" "${sites_json}" "${slot_ids}"
        ;;
      restore)
        restore_plan "${plan_json}" "${sites_json}" "${slot_ids}"
        ;;
      delete)
        delete_plan "${plan_json}" "${sites_json}" "${slot_ids}"
        ;;
    esac
  done < <(jq -c '.[]' <<<"${plans_json}")
}

ACTION="${1:-}"
case "${ACTION}" in
  -h|--help)
    usage
    exit 0
    ;;
  disable|restore|delete)
    ;;
  *)
    usage
    fail "Action must be disable, restore or delete"
    ;;
esac

[[ -n "${SUBSCRIPTION_NAME:-}" ]] || fail "SUBSCRIPTION_NAME is required"
[[ "${SUBSCRIPTION_NAME}" == "${EXPECTED_SUBSCRIPTION}" ]] \
  || fail "SUBSCRIPTION_NAME must be '${EXPECTED_SUBSCRIPTION}'; got '${SUBSCRIPTION_NAME}'"

TARGETS_FILE="${TARGETS_FILE:-${script_dir}/snd-app-services-targets.txt}"
[[ -f "${TARGETS_FILE}" ]] || fail "Targets file '${TARGETS_FILE}' was not found"

DRY_RUN_ENABLED="$(normalise_bool "${DRY_RUN:-true}")"

REAL_DELETE=false
if [[ "${ACTION}" == "delete" && "${DELETE_ENABLED}" == "true" && "${DRY_RUN_ENABLED}" == "false" ]]; then
  REAL_DELETE=true
fi
readonly REAL_DELETE

# Only the delete dry run is locked because a real delete cannot run under a lock
if [[ "${ACTION}" == "delete" && "${REAL_DELETE}" != "true" ]]; then
  LOCK_MODE=apply
else
  LOCK_MODE=none
fi
readonly LOCK_MODE

targets="$(read_targets)"
[[ -n "${targets}" ]] || fail "Targets file '${TARGETS_FILE}' has no resource groups"

log "Action=${ACTION} Subscription=${SUBSCRIPTION_NAME} DryRun=${DRY_RUN_ENABLED} DeleteEnabled=${DELETE_ENABLED} Locks=${LOCK_MODE}"
if [[ "${ACTION}" == "delete" && "${REAL_DELETE}" != "true" ]]; then
  log "Delete is a dry run, nothing will be deleted"
fi

# Check every target before changing anything
while IFS= read -r resource_group; do
  validate_resource_group "${resource_group}"
done <<<"${targets}"

if [[ "${ACTION}" == "disable" ]]; then
  load_autoscale_settings
fi

# Unlock on any exit so a failed or cancelled run does not leave locks behind
trap unlock_resource_groups EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
lock_resource_groups "${targets}"

while IFS= read -r resource_group; do
  process_resource_group "${resource_group}"
done <<<"${targets}"

log "Done"
