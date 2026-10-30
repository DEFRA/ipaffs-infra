#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: snd-app-services.sh <action>

Actions:
  disable  Record the original plan size as tags, turn autoscale off, stop
           all apps and slots, turn off File Change Audit logs that need a
           Premium plan, then scale each plan to B1 (S1 when it hosts slots).
           Zone redundant plans keep their instance count and Premium logs
           and scale to P0v3 instead.
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
  PARALLEL_JOBS      Apps changed at the same time within a plan; defaults to 4.

In the pipeline the script signs in again every 30 minutes, because the federated
sign in from the AzureCLI task stops working after about an hour. This needs
SYSTEM_ACCESSTOKEN and the AZURESUBSCRIPTION_* variables the task sets.
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
# Apps and slots disable stopped are listed on the plan because tagging each app takes about 12 seconds
# A tag value holds 256 characters so the list is split across ipaffs-stopped-1, ipaffs-stopped-2 and so on
readonly TAG_STOPPED_PREFIX="ipaffs-stopped-"
readonly TAG_VALUE_LIMIT=256

# These log categories need a Premium plan so they are turned off before scaling down
# Azure hides them on smaller plans and only shows them again after scaling back up
# Zone redundant plans must stay Premium so they drop to the smallest Premium size
readonly ZONE_REDUNDANT_SKU="P0v3"
readonly PREMIUM_LOG_CATEGORIES='["AppServiceFileAuditLogs","AppServiceAntivirusScanAuditLogs"]'
readonly TAG_FILE_AUDIT_OFF="ipaffs-file-audit-off"
readonly RESTORE_LOG_ATTEMPTS="${RESTORE_LOG_ATTEMPTS:-18}"
readonly RESTORE_LOG_DELAY_SECONDS="${RESTORE_LOG_DELAY_SECONDS:-10}"

# A delete run locks its resource groups against deletion and unlocks them at the end
readonly RUN_LOCK_NAME="ipaffs-pipeline-run"
readonly RUN_LOCK_NOTES="Added by the SND App Services pipeline for the duration of a run"

LOCKED_GROUPS=""

# Signs in again well before the pipeline token runs out
readonly THROTTLE_ATTEMPTS="${THROTTLE_ATTEMPTS:-6}"
readonly THROTTLE_DELAY_SECONDS="${THROTTLE_DELAY_SECONDS:-20}"
readonly LOGIN_REFRESH_SECONDS="${LOGIN_REFRESH_SECONDS:-1800}"
LAST_LOGIN="$(date +%s)"

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

# One write per line so parallel jobs do not mix their output
print_dry_run() {
  local line

  line="$(printf "%q " "$@")"
  printf "DRY RUN: %s\n" "${line}"
}

# Retries when Azure throttles the subscription and fails on any other error
run_cmd() {
  local attempt output status

  if [[ "${DRY_RUN_ENABLED}" == "true" ]]; then
    print_dry_run "$@"
    return 0
  fi

  for (( attempt = 1; ; attempt++ )); do
    status=0
    output="$("$@" 2>&1)" || status=$?
    if [[ "${status}" -eq 0 ]]; then
      [[ -z "${output}" ]] || echo "${output}"
      return 0
    fi
    if [[ "${attempt}" -ge "${THROTTLE_ATTEMPTS}" ]] || ! grep -qiE '"Code":"429"|TooManyRequests|throttled' <<<"${output}"; then
      echo "${output}" >&2
      return "${status}"
    fi
    log "Azure is throttling, retrying '${1} ${2}' in $(( attempt * THROTTLE_DELAY_SECONDS )) seconds"
    sleep "$(( attempt * THROTTLE_DELAY_SECONDS ))"
  done
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

# Starts or stops an app or slot
# A slot id given to ids acts on the parent app so slots are passed by name
app_power() {
  local app_cli="${1}"
  local action="${2}"
  local resource_id="${3}"
  local site_id="${resource_id%%/slots/*}"

  if [[ "${resource_id}" == "${site_id}" ]]; then
    run_cmd az "${app_cli}" "${action}" --ids "${resource_id}"
    return
  fi
  run_cmd az "${app_cli}" "${action}" \
    --subscription "${SUBSCRIPTION_NAME}" \
    --resource-group "$(cut -d / -f 5 <<<"${site_id}")" \
    --name "${site_id##*/}" \
    --slot "${resource_id##*/slots/}"
}

# Runs a function for each input line a batch at a time and fails if any run failed
# Callers must not use it in a condition because bash then ignores set -e in the jobs
run_parallel() {
  local function_name="${1}"
  local failure_message="${2}"
  local line pid pids="" count=0 failed=0

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    "${function_name}" "${line}" </dev/null &
    pids+="${!} "
    count=$((count + 1))
    if (( count % PARALLEL_JOBS == 0 )); then
      for pid in ${pids}; do
        wait "${pid}" || failed=1
      done
      pids=""
    fi
  done

  for pid in ${pids}; do
    wait "${pid}" || failed=1
  done
  [[ "${failed}" -eq 0 ]] || fail "${failure_message}"
}

login_refresh_available() {
  [[ -n "${SYSTEM_OIDCREQUESTURI:-}" && -n "${SYSTEM_ACCESSTOKEN:-}" \
    && -n "${AZURESUBSCRIPTION_SERVICE_CONNECTION_ID:-}" && -n "${AZURESUBSCRIPTION_CLIENT_ID:-}" \
    && -n "${AZURESUBSCRIPTION_TENANT_ID:-}" ]]
}

# Asks Azure DevOps for a new federated token and signs in with it
refresh_login() {
  local now token

  login_refresh_available || return 0
  now="$(date +%s)"
  (( now - LAST_LOGIN >= LOGIN_REFRESH_SECONDS )) || return 0

  log "Signing in to Azure again with a new federated token"
  token="$(curl -sSf -X POST \
    -H "Authorization: Bearer ${SYSTEM_ACCESSTOKEN}" \
    -H "Content-Type: application/json" \
    -H "Content-Length: 0" \
    "${SYSTEM_OIDCREQUESTURI}?api-version=7.1&serviceConnectionId=${AZURESUBSCRIPTION_SERVICE_CONNECTION_ID}" \
    | jq -r '.oidcToken // empty')"
  [[ -n "${token}" ]] || fail "Azure DevOps did not return a federated token"

  az login \
    --service-principal \
    --username "${AZURESUBSCRIPTION_CLIENT_ID}" \
    --tenant "${AZURESUBSCRIPTION_TENANT_ID}" \
    --federated-token "${token}" \
    --allow-no-subscriptions \
    --output none
  az account set --subscription "${SUBSCRIPTION_NAME}"
  LAST_LOGIN="${now}"
}

resource_tag() {
  az tag list --resource-id "${1}" --query "properties.tags.\"${2}\"" --output tsv
}

# Prints the apps and slots listed in the plan stop tags, one per line
recorded_stops() {
  jq -r --arg prefix "${TAG_STOPPED_PREFIX}" \
    '.tags // {} | to_entries[] | select(.key | startswith($prefix)) | .value | split(",")[] | select(. != "")' \
    <<<"${1}" | sort -u
}

# Prints the names of the plan stop tags
stop_tag_names() {
  jq -r --arg prefix "${TAG_STOPPED_PREFIX}" '.tags // {} | keys[] | select(startswith($prefix))' <<<"${1}"
}

# Splits a list of names into key=value tags that each fit the tag value limit
stop_tags() {
  awk -v prefix="${TAG_STOPPED_PREFIX}" -v limit="${TAG_VALUE_LIMIT}" '
    NF == 0 { next }
    value != "" && length(value) + 1 + length($0) > limit { print prefix (++n) "=" value; value = "" }
    { value = (value == "" ? $0 : value "," $0) }
    END { if (value != "") print prefix (++n) "=" value }
  ' <<<"${1}"
}

# Tags the app with each setting and category it turns off so a rerun keeps the full list
disable_premium_logs() {
  local resource_id="${1}"
  local recorded="${2}"
  local settings setting_name category log_index

  settings="$(az monitor diagnostic-settings list --resource "${resource_id}" --output json \
    | jq -r --argjson categories "${PREMIUM_LOG_CATEGORIES}" \
      '.[] | .name as $name | .logs | to_entries[]
        | select(.value.enabled and (.value.category as $c | $categories | index($c)))
        | [$name, .value.category, .key] | @tsv')"
  [[ -n "${settings}" ]] || return 0

  run_cmd az tag update \
    --resource-id "${resource_id}" \
    --operation Merge \
    --tags "${TAG_FILE_AUDIT_OFF}=$( { tr ',' '\n' <<<"${recorded}"; cut -f1,2 <<<"${settings}" | tr '\t' ':'; } | grep -v '^$' | sort -u | paste -sd, -)" \
    --output none

  while IFS=$'\t' read -r setting_name category log_index; do
    log "Turning off ${category} in diagnostic setting '${setting_name}' on '${resource_id##*/sites/}'"
    run_cmd az monitor diagnostic-settings update \
      --resource "${resource_id}" \
      --name "${setting_name}" \
      --set "logs[${log_index}].enabled=false" \
      --output none
  done <<<"${settings}"
}

# Runs in the background and reads slot_ids and premium_logs_off from disable_plan
disable_site() {
  local site_json="${1}"
  local site_id site_name site_state app_cli slot_id site_slots

  site_id="$(jq -r '.id' <<<"${site_json}")"
  site_name="$(jq -r '.name' <<<"${site_json}")"
  site_state="$(jq -r '.state // ""' <<<"${site_json}")"
  app_cli="$(app_cli_for_kind "$(jq -r '.kind // ""' <<<"${site_json}")")"
  site_slots="$(slots_for_site "${site_id}" "${slot_ids}")"

  while IFS= read -r slot_id; do
    [[ -n "${slot_id}" ]] || continue
    log "Stopping slot '${slot_id##*/sites/}'"
    app_power "${app_cli}" stop "${slot_id}"
  done <<<"${site_slots}"

  if [[ "$(lowercase "${site_state}")" == "stopped" ]]; then
    log "App '${site_name}' is already stopped"
  else
    log "Stopping ${app_cli} '${site_name}'"
    app_power "${app_cli}" stop "${site_id}"
  fi

  [[ "${premium_logs_off}" == "true" ]] || return 0
  disable_premium_logs "${site_id}" "$(jq -r --arg tag "${TAG_FILE_AUDIT_OFF}" '.tags[$tag] // ""' <<<"${site_json}")"
  while IFS= read -r slot_id; do
    [[ -n "${slot_id}" ]] || continue
    disable_premium_logs "${slot_id}" ""
  done <<<"${site_slots}"
}

disable_plan() {
  local plan_json="${1}"
  local sites_json="${2}"
  local slot_ids="${3}"
  local plan_id plan_name sku capacity disabled_tag plan_sites plan_slots target_sku target_capacity
  local scale_needed premium_logs_off
  local autoscale_enabled autoscale_off autoscale_name autoscale_group site_json
  local recorded to_stop tag
  local plan_tags=()

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
  target_capacity=1
  premium_logs_off=true
  if [[ "$(jq -r '.zoneRedundant // false' <<<"${plan_json}")" == "true" ]]; then
    target_sku="${ZONE_REDUNDANT_SKU}"
    target_capacity="${capacity}"
    premium_logs_off=false
  fi

  autoscale_off="$(jq -r --arg plan "$(lowercase "${plan_id}")" \
    '[.[] | select((.target // "" | ascii_downcase) == $plan and .enabled == true) | "\(.resourceGroup)/\(.name)"] | join(",")' \
    <<<"${AUTOSCALE_JSON}")"
  autoscale_enabled=false
  [[ -z "${autoscale_off}" ]] || autoscale_enabled=true

  log "Disabling plan '${plan_name}' (${sku} x${capacity}, autoscale ${autoscale_enabled}) to ${target_sku} x${target_capacity}"

  # Running apps and every slot are added to what earlier runs recorded
  recorded="$(recorded_stops "${plan_json}")"
  to_stop="$( {
    echo "${recorded}"
    jq -r 'select((.state // "" | ascii_downcase) != "stopped") | .name' <<<"${plan_sites}"
    sed 's#.*/sites/##' <<<"${plan_slots}"
  } | grep -v '^$' | sort -u || true)"

  # Record the original size once so a rerun never overwrites it
  if [[ -z "${disabled_tag}" ]]; then
    plan_tags=(
      "${TAG_ORIGINAL_SKU}=${sku}"
      "${TAG_ORIGINAL_CAPACITY}=${capacity}"
      "${TAG_AUTOSCALE_OFF}=${autoscale_off:-none}"
      "${TAG_DISABLED}=$(date -u +"%Y-%m-%d")"
    )
  else
    log "Plan '${plan_name}' was already disabled on ${disabled_tag}, keeping its original tags"
  fi
  if [[ "${to_stop}" != "${recorded}" ]]; then
    while IFS= read -r tag; do
      plan_tags+=("${tag}")
    done < <(stop_tags "${to_stop}")
  fi

  # Everything restore needs is written before anything changes
  if [[ "${#plan_tags[@]}" -gt 0 ]]; then
    run_cmd az tag update --resource-id "${plan_id}" --operation Merge --tags "${plan_tags[@]}" --output none
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

  scale_needed=true
  [[ "${sku}" != "${target_sku}" || "${capacity}" != "${target_capacity}" ]] || scale_needed=false
  [[ "${scale_needed}" == "true" ]] || premium_logs_off=false

  # Every app must be done before the plan is scaled
  run_parallel disable_site "Could not disable every app on plan '${plan_name}'; it was not scaled down" <<<"${plan_sites}"

  if [[ "${scale_needed}" != "true" ]]; then
    log "Plan '${plan_name}' is already ${target_sku} x${target_capacity}"
  else
    run_cmd az appservice plan update \
      --ids "${plan_id}" \
      --sku "${target_sku}" \
      --number-of-workers "${target_capacity}" \
      --output none
  fi
}

# Waits for a hidden category to come back after the plan is scaled up
premium_log_index() {
  local resource_id="${1}"
  local setting_name="${2}"
  local category="${3}"
  local attempt log_index

  for (( attempt = 1; attempt <= RESTORE_LOG_ATTEMPTS; attempt++ )); do
    log_index="$(az monitor diagnostic-settings show --resource "${resource_id}" --name "${setting_name}" --output json \
      | jq -r --arg category "${category}" '.logs | map(.category) | index($category) // empty')"
    if [[ -n "${log_index}" || "${DRY_RUN_ENABLED}" == "true" ]]; then
      echo "${log_index}"
      return 0
    fi
    sleep "${RESTORE_LOG_DELAY_SECONDS}"
  done
}

# Turns back on the categories disable recorded and keeps the tag if any is still hidden
restore_premium_logs() {
  local resource_id="${1}"
  local recorded="${2}"
  local entry setting_name category log_index

  [[ -n "${recorded}" ]] || return 0

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    setting_name="${entry%%:*}"
    category="${entry#*:}"
    log_index="$(premium_log_index "${resource_id}" "${setting_name}" "${category}")"
    if [[ -z "${log_index}" ]]; then
      [[ "${DRY_RUN_ENABLED}" == "true" ]] \
        || fail "${category} did not come back in diagnostic setting '${setting_name}' on '${resource_id##*/sites/}'"
      log "${category} in diagnostic setting '${setting_name}' on '${resource_id##*/sites/}' is hidden until the plan is scaled up"
      continue
    fi
    log "Turning on ${category} in diagnostic setting '${setting_name}' on '${resource_id##*/sites/}'"
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
  local recorded_logs="${3}"

  restore_premium_logs "${resource_id}" "${recorded_logs}"

  grep -qxF "${resource_id##*/sites/}" <<<"${stopped_list}" || return 0
  log "Starting ${app_cli} '${resource_id##*/sites/}'"
  app_power "${app_cli}" start "${resource_id}"
}

# Runs in the background and reads slot_ids and stopped_list from restore_plan
restore_site() {
  local site_json="${1}"
  local site_id app_cli slot_id

  site_id="$(jq -r '.id' <<<"${site_json}")"
  app_cli="$(app_cli_for_kind "$(jq -r '.kind // ""' <<<"${site_json}")")"

  # Slot tags are not in the app listing so they are read one by one
  while IFS= read -r slot_id; do
    [[ -n "${slot_id}" ]] || continue
    restore_resource "${app_cli}" "${slot_id}" "$(resource_tag "${slot_id}" "${TAG_FILE_AUDIT_OFF}")"
  done < <(slots_for_site "${site_id}" "${slot_ids}")

  restore_resource "${app_cli}" "${site_id}" \
    "$(jq -r --arg tag "${TAG_FILE_AUDIT_OFF}" '.tags[$tag] // ""' <<<"${site_json}")"
}

restore_plan() {
  local plan_json="${1}"
  local sites_json="${2}"
  local slot_ids="${3}"
  local plan_id plan_name sku capacity disabled_tag original_sku original_capacity autoscale_off
  local autoscale autoscale_name autoscale_group plan_sites stopped_list tag
  local tag_names=()

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
  stopped_list="$(recorded_stops "${plan_json}")"
  run_parallel restore_site "Could not restore every app on plan '${plan_name}'; its tags were kept so restore can be rerun" <<<"${plan_sites}"

  # The plan tags go last so a failed restore can be rerun
  tag_names=("${TAG_ORIGINAL_SKU}" "${TAG_ORIGINAL_CAPACITY}" "${TAG_AUTOSCALE_OFF}" "${TAG_DISABLED}")
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tag_names+=("${tag}")
  done < <(stop_tag_names "${plan_json}")
  run_cmd az tag update --resource-id "${plan_id}" --operation Delete --tags "${tag_names[@]}" --output none
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
    --query "[].{id:id, name:name, resourceGroup:resourceGroup, sku:sku.name, capacity:sku.capacity, zoneRedundant:zoneRedundant, tags:tags}" \
    --output json)"
  sites_json="$(list_sites "${resource_group}")"
  slot_ids="$(list_slot_ids "${resource_group}")"

  log "Found $(jq 'length' <<<"${plans_json}") plan(s), $(jq 'length' <<<"${sites_json}") app(s) and $(grep -c . <<<"${slot_ids}" || true) slot(s)"

  while IFS= read -r plan_json; do
    [[ -n "${plan_json}" ]] || continue
    refresh_login
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

PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
[[ "${PARALLEL_JOBS}" =~ ^[1-9][0-9]*$ ]] || fail "PARALLEL_JOBS must be a positive whole number; got '${PARALLEL_JOBS}'"
readonly PARALLEL_JOBS

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
if login_refresh_available; then
  log "Sign in is refreshed every ${LOGIN_REFRESH_SECONDS} seconds"
elif [[ -n "${SYSTEM_OIDCREQUESTURI:-}" ]]; then
  log "WARNING: sign in cannot be refreshed so a run over an hour may fail"
fi
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
