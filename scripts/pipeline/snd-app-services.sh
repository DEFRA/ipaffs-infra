#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: snd-app-services.sh <action>

Actions:
  disable  Record the original plan size as tags, turn autoscale off, stop
           all apps and slots, then scale each plan to B1 (S1 when it hosts slots).
  delete   List the slots, apps and plans that would be deleted.
           Always a dry run until DELETE_ENABLED is changed in this script.

Each run adds a CanNotDelete lock named ipaffs-pipeline-run to every listed
resource group before any change, and removes it when the run ends.

Environment:
  SUBSCRIPTION_NAME  Must be AZR-SND.
  TARGETS_FILE       Resource group allowlist; defaults to snd-app-services-targets.txt.
  DRY_RUN            true or false for disable; defaults to true.
USAGE
}

# Delete stays a dry run until this is changed in a reviewed pull request
readonly DELETE_ENABLED=false

readonly EXPECTED_SUBSCRIPTION="AZR-SND"
readonly RESOURCE_GROUP_PREFIX="SNDIMP"
readonly TAG_ORIGINAL_SKU="ipaffs-original-sku"
readonly TAG_ORIGINAL_CAPACITY="ipaffs-original-capacity"
readonly TAG_AUTOSCALE_ENABLED="ipaffs-autoscale-enabled"
readonly TAG_DISABLED="ipaffs-disabled"

# Each run locks its resource groups against deletion and unlocks them at the end
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
  local -a lock_command

  [[ "${LOCK_MODE}" != "none" ]] || return 0

  while IFS= read -r resource_group; do
    lock_command=(az lock create
      --subscription "${SUBSCRIPTION_NAME}"
      --resource-group "${resource_group}"
      --name "${RUN_LOCK_NAME}"
      --lock-type CanNotDelete
      --notes "${RUN_LOCK_NOTES}"
      --output none)

    if [[ "${LOCK_MODE}" == "print" ]]; then
      print_dry_run "${lock_command[@]}"
      continue
    fi

    log "Locking resource group '${resource_group}' with CanNotDelete lock '${RUN_LOCK_NAME}'"
    "${lock_command[@]}"
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
  local query="[].{id:id, name:name, kind:kind, state:state, plan:appServicePlanId}"
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

disable_plan() {
  local plan_json="${1}"
  local sites_json="${2}"
  local slot_ids="${3}"
  local plan_id plan_name sku capacity disabled_tag plan_sites plan_slots target_sku
  local autoscale_enabled autoscale_name autoscale_group site_json site_id site_name site_kind site_state slot_id app_cli

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

  autoscale_enabled="$(jq -r --arg plan "$(lowercase "${plan_id}")" \
    'any(.[]; (.target // "" | ascii_downcase) == $plan and .enabled == true)' <<<"${AUTOSCALE_JSON}")"

  log "Disabling plan '${plan_name}' (${sku} x${capacity}, autoscale ${autoscale_enabled}) to ${target_sku} x1"

  # Record the original size once so a rerun never overwrites it
  if [[ -z "${disabled_tag}" ]]; then
    run_cmd az tag update \
      --resource-id "${plan_id}" \
      --operation Merge \
      --tags \
        "${TAG_ORIGINAL_SKU}=${sku}" \
        "${TAG_ORIGINAL_CAPACITY}=${capacity}" \
        "${TAG_AUTOSCALE_ENABLED}=${autoscale_enabled}" \
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
      run_cmd az "${app_cli}" stop --ids "${slot_id}"
    done < <(slots_for_site "${site_id}" "${slot_ids}")

    if [[ "$(lowercase "${site_state}")" == "stopped" ]]; then
      log "App '${site_name}' is already stopped"
    else
      log "Stopping ${app_cli} '${site_name}'"
      run_cmd az "${app_cli}" stop --ids "${site_id}"
    fi
  done <<<"${plan_sites}"

  if [[ "${sku}" == "${target_sku}" && "${capacity}" == "1" ]]; then
    log "Plan '${plan_name}' is already ${target_sku} x1"
  else
    run_cmd az appservice plan update \
      --ids "${plan_id}" \
      --sku "${target_sku}" \
      --number-of-workers 1 \
      --output none
  fi
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
  disable|delete)
    ;;
  *)
    usage
    fail "Action must be disable or delete"
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

# A real delete cannot run under a lock and a local disable dry run only prints it
if [[ "${REAL_DELETE}" == "true" ]]; then
  LOCK_MODE=none
elif [[ "${ACTION}" == "disable" && "${DRY_RUN_ENABLED}" == "true" ]]; then
  LOCK_MODE=print
else
  LOCK_MODE=apply
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
