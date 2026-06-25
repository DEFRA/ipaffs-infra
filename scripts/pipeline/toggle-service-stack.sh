#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: toggle-service-stack.sh <action>

Actions:
  stop-old-stack   Stop matching old-stack Azure App Services / Function Apps.
  start-old-stack  Start matching old-stack Azure App Services / Function Apps.
  suspend-k8s      Suspend matching K8s CronJobs / KEDA ScaledJobs, or scale configured Deployments down.
  unsuspend-k8s    Unsuspend matching K8s CronJobs / KEDA ScaledJobs, or scale configured Deployments up.

Environment:
  ENVIRONMENT                 tst, pre or prd.
  SERVICE_GROUP               event-driven-services or time-triggered-services.
  NAMESPACE                   K8s namespace; defaults to ENVIRONMENT.
  CLASSIC_SUBSCRIPTION_NAME   Required for old-stack actions.
  DRY_RUN                     true or false; defaults to true.

Configured K8s env var toggles are applied during suspend-k8s and unsuspend-k8s.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
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

normalise_environment() {
  case "$(lowercase "${1:-}")" in
    tst|pre|prd)
      lowercase "${1}"
      ;;
    *)
      fail "ENVIRONMENT must be one of tst, pre or prd; got '${1:-unset}'"
      ;;
  esac
}

normalise_service_group() {
  case "$(lowercase "${1:-event-driven-services}")" in
    event-driven|event-driven-services)
      echo "event-driven-services"
      ;;
    time-triggered|time-triggered-services)
      echo "time-triggered-services"
      ;;
    *)
      fail "SERVICE_GROUP must be event-driven-services or time-triggered-services; got '${1}'"
      ;;
  esac
}

target_mappings() {
  case "${SERVICE_GROUP_NAME}" in
    event-driven-services)
      cat <<'TARGETS'
gvms-service|gvms-microservice|functionapp
notify-service|notify-microservice|functionapp
dmpintegration-service|dmp-integration-microservice|functionapp
enotificationeventlistener-service|enotification-event-listener-microservice|functionapp
enotificationprocessing-service|enotification-processing-microservice|webapp
bulkupload-service|bulk-upload-microservice|webapp
TARGETS
      ;;
    time-triggered-services)
      cat <<'TARGETS'
archivenotifications-job|archive-notifications-microservice|functionapp
autoclearance-job|auto-clearance-microservice|functionapp
riskinterface-job|risk-interface-microservice|functionapp
risklocking-job|risk-locking-microservice|functionapp
referencedataloader-service|referencedataloader-microservice-blue|webapp|3|0
TARGETS
      ;;
    *)
      fail "Unsupported service group '${SERVICE_GROUP_NAME}'"
      ;;
  esac
}

k8s_config_mappings() {
  case "${SERVICE_GROUP_NAME}" in
    time-triggered-services)
      cat <<'TARGETS'
notification-service|ARCHIVE_NOTIFICATIONS_SCHEDULER_ENABLED|true|false
bip-service|MDM_DOWNLOAD_SCHEDULER_ENABLED|true|false
TARGETS
      ;;
    *)
      ;;
  esac
}

print_command() {
  printf "%q " "$@"
  printf "\n"
}

run_cmd() {
  if [[ "${DRY_RUN_ENABLED}" == "true" ]]; then
    printf "DRY RUN: "
    print_command "$@"
    return 0
  fi

  "$@"
}

old_stack_resource_name() {
  local old_base="${1}"
  printf "%s-%s\n" "${old_base}" "${ENVIRONMENT_NAME}"
}

lookup_old_stack_resource_id() {
  local resource_name="${1}"

  az resource list \
    --subscription "${CLASSIC_SUBSCRIPTION_NAME}" \
    --resource-type "Microsoft.Web/sites" \
    --query "[?name=='${resource_name}'].id | [0]" \
    --output tsv
}

resource_group_from_id() {
  local resource_id="${1}"
  local -a segments

  IFS='/' read -r -a segments <<<"${resource_id}"
  for ((i = 0; i < ${#segments[@]}; i++)); do
    if [[ "$(lowercase "${segments[$i]}")" == "resourcegroups" ]]; then
      [[ $((i + 1)) -lt ${#segments[@]} ]] || fail "Could not parse resource group from resource ID '${resource_id}'"
      echo "${segments[$((i + 1))]}"
      return 0
    fi
  done

  fail "Could not parse resource group from resource ID '${resource_id}'"
}

old_stack_cli_for_kind() {
  case "${1}" in
    functionapp)
      echo "az functionapp"
      ;;
    webapp)
      echo "az webapp"
      ;;
    *)
      fail "Old-stack kind must be functionapp or webapp; got '${1}'"
      ;;
  esac
}

run_old_stack_action() {
  local action="${1}"
  local k8s_name old_base old_stack_kind unsuspend_replicas suspend_replicas resource_name resource_id resource_group
  local -a app_cli

  [[ -n "${CLASSIC_SUBSCRIPTION_NAME:-}" ]] || fail "CLASSIC_SUBSCRIPTION_NAME is required for ${action}"

  while IFS='|' read -r k8s_name old_base old_stack_kind unsuspend_replicas suspend_replicas; do
    [[ -n "${k8s_name}" && -n "${old_base}" && -n "${old_stack_kind}" ]] || continue

    resource_name="$(old_stack_resource_name "${old_base}")"
    log "Resolving old-stack resource '${resource_name}' for K8s service '${k8s_name}'"

    resource_id="$(lookup_old_stack_resource_id "${resource_name}")"
    [[ -n "${resource_id}" ]] || fail "Could not find old-stack App Service or Function App '${resource_name}' in subscription '${CLASSIC_SUBSCRIPTION_NAME}'"

    resource_group="$(resource_group_from_id "${resource_id}")"
    read -r -a app_cli <<<"$(old_stack_cli_for_kind "${old_stack_kind}")"

    case "${action}" in
      stop-old-stack)
        log "Stopping old-stack resource '${resource_name}' in resource group '${resource_group}'"
        run_cmd "${app_cli[@]}" stop --ids "${resource_id}"
        ;;
      start-old-stack)
        log "Starting old-stack resource '${resource_name}' in resource group '${resource_group}'"
        run_cmd "${app_cli[@]}" start --ids "${resource_id}"
        ;;
      *)
        fail "Unsupported old-stack action '${action}'"
        ;;
    esac
  done < <(target_mappings)
}

k8s_workload_kind() {
  local k8s_name="${1}"

  if kubectl --namespace "${NAMESPACE_NAME}" get scaledjob.keda.sh "${k8s_name}" >/dev/null 2>&1; then
    echo "scaledjob.keda.sh"
    return 0
  fi

  if kubectl --namespace "${NAMESPACE_NAME}" get cronjob.batch "${k8s_name}" >/dev/null 2>&1; then
    echo "cronjob.batch"
    return 0
  fi

  if kubectl --namespace "${NAMESPACE_NAME}" get deployment.apps "${k8s_name}" >/dev/null 2>&1; then
    echo "deployment.apps"
    return 0
  fi

  fail "Could not find K8s workload '${k8s_name}' as ScaledJob, CronJob or Deployment in namespace '${NAMESPACE_NAME}'"
}

run_k8s_action() {
  local action="${1}"
  local k8s_name old_base old_stack_kind unsuspend_replicas suspend_replicas workload_kind

  while IFS='|' read -r k8s_name old_base old_stack_kind unsuspend_replicas suspend_replicas; do
    [[ -n "${k8s_name}" && -n "${old_base}" ]] || continue

    workload_kind="$(k8s_workload_kind "${k8s_name}")"
    log "Applying '${action}' to '${k8s_name}' (${workload_kind}) in namespace '${NAMESPACE_NAME}'"

    case "${action}:${workload_kind}" in
      suspend-k8s:scaledjob.keda.sh)
        run_cmd kubectl --namespace "${NAMESPACE_NAME}" patch scaledjob.keda.sh "${k8s_name}" \
          --type merge \
          --patch '{"metadata":{"annotations":{"autoscaling.keda.sh/paused":"true"}}}'
        ;;
      unsuspend-k8s:scaledjob.keda.sh)
        run_cmd kubectl --namespace "${NAMESPACE_NAME}" patch scaledjob.keda.sh "${k8s_name}" \
          --type merge \
          --patch '{"metadata":{"annotations":{"autoscaling.keda.sh/paused":null}}}'
        ;;
      suspend-k8s:cronjob.batch)
        run_cmd kubectl --namespace "${NAMESPACE_NAME}" patch cronjob.batch "${k8s_name}" \
          --type merge \
          --patch '{"spec":{"suspend":true}}'
        ;;
      unsuspend-k8s:cronjob.batch)
        run_cmd kubectl --namespace "${NAMESPACE_NAME}" patch cronjob.batch "${k8s_name}" \
          --type merge \
          --patch '{"spec":{"suspend":false}}'
        ;;
      suspend-k8s:deployment.apps)
        [[ -n "${suspend_replicas}" ]] || fail "No suspend replica count configured for Deployment '${k8s_name}'"
        log "Scaling Deployment '${k8s_name}' to ${suspend_replicas} replicas"
        run_cmd kubectl --namespace "${NAMESPACE_NAME}" scale deployment.apps "${k8s_name}" \
          --replicas="${suspend_replicas}"
        ;;
      unsuspend-k8s:deployment.apps)
        [[ -n "${unsuspend_replicas}" ]] || fail "No unsuspend replica count configured for Deployment '${k8s_name}'"
        log "Scaling Deployment '${k8s_name}' to ${unsuspend_replicas} replicas"
        run_cmd kubectl --namespace "${NAMESPACE_NAME}" scale deployment.apps "${k8s_name}" \
          --replicas="${unsuspend_replicas}"
        ;;
      *)
        fail "Unsupported K8s action '${action}' for workload kind '${workload_kind}'"
        ;;
    esac
  done < <(target_mappings)
}

run_k8s_config_action() {
  local action="${1}"
  local service_name config_key enabled_value disabled_value desired_value patch

  while IFS='|' read -r service_name config_key enabled_value disabled_value; do
    [[ -n "${service_name}" && -n "${config_key}" ]] || continue

    case "${action}" in
      unsuspend-k8s)
        desired_value="${enabled_value}"
        ;;
      suspend-k8s)
        desired_value="${disabled_value}"
        ;;
      *)
        fail "Unsupported K8s config action '${action}'"
        ;;
    esac

    patch="{\"data\":{\"${config_key}\":\"${desired_value}\"}}"
    log "Setting '${config_key}' to '${desired_value}' on ConfigMap '${service_name}' in namespace '${NAMESPACE_NAME}'"
    run_cmd kubectl --namespace "${NAMESPACE_NAME}" patch configmap "${service_name}" \
      --type merge \
      --patch "${patch}"

    log "Restarting Deployment '${service_name}' to load '${config_key}=${desired_value}'"
    run_cmd kubectl --namespace "${NAMESPACE_NAME}" rollout restart deployment.apps "${service_name}"
    run_cmd kubectl --namespace "${NAMESPACE_NAME}" rollout status deployment.apps "${service_name}" --timeout=10m
  done < <(k8s_config_mappings)
}

ACTION="${1:-}"
case "${ACTION}" in
  -h|--help)
    usage
    exit 0
    ;;
  stop-old-stack|start-old-stack|suspend-k8s|unsuspend-k8s)
    ;;
  *)
    usage
    fail "Action must be stop-old-stack, start-old-stack, suspend-k8s or unsuspend-k8s"
    ;;
esac

ENVIRONMENT_NAME="$(normalise_environment "${ENVIRONMENT:-}")"
SERVICE_GROUP_NAME="$(normalise_service_group "${SERVICE_GROUP:-event-driven-services}")"
NAMESPACE_NAME="$(lowercase "${NAMESPACE:-${ENVIRONMENT_NAME}}")"
DRY_RUN_ENABLED="$(normalise_bool "${DRY_RUN:-true}")"

if [[ "${NAMESPACE_NAME}" != "${ENVIRONMENT_NAME}" ]]; then
  fail "NAMESPACE '${NAMESPACE_NAME}' must match ENVIRONMENT '${ENVIRONMENT_NAME}'"
fi

log "Action=${ACTION} ServiceGroup=${SERVICE_GROUP_NAME} Environment=${ENVIRONMENT_NAME} Namespace=${NAMESPACE_NAME} DryRun=${DRY_RUN_ENABLED}"

case "${ACTION}" in
  stop-old-stack|start-old-stack)
    run_old_stack_action "${ACTION}"
    ;;
  suspend-k8s|unsuspend-k8s)
    run_k8s_config_action "${ACTION}"
    run_k8s_action "${ACTION}"
    ;;
esac
