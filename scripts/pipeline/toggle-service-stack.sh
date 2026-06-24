#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: toggle-service-stack.sh <action>

Actions:
  stop-old-stack   Stop matching old-stack Azure App Services / Function Apps.
  start-old-stack  Start matching old-stack Azure App Services / Function Apps.
  suspend-k8s      Suspend matching K8s CronJobs / KEDA ScaledJobs.
  unsuspend-k8s    Unsuspend matching K8s CronJobs / KEDA ScaledJobs.

Environment:
  ENVIRONMENT                 tst, pre or prd.
  SERVICE_GROUP               event-driven-services or time-triggered-services.
  NAMESPACE                   K8s namespace; defaults to ENVIRONMENT.
  CLASSIC_SUBSCRIPTION_NAME   Required for old-stack actions.
  DRY_RUN                     true or false; defaults to true.
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
gvms-service|gvms-microservice
notify-service|notify-microservice
dmpintegration-service|dmp-integration-microservice
enotificationeventlistener-service|enotification-event-listener-microservice
enotificationprocessing-service|enotification-processing-microservice
bulkupload-service|bulk-upload-microservice
TARGETS
      ;;
    time-triggered-services)
      cat <<'TARGETS'
archivenotifications-job|archive-notifications-microservice
autoclearance-job|auto-clearance-microservice
riskinterface-job|risk-interface-microservice
risklocking-job|risk-locking-microservice
TARGETS
      ;;
    *)
      fail "Unsupported service group '${SERVICE_GROUP_NAME}'"
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

lookup_old_stack_resource() {
  local resource_name="${1}"

  az resource list \
    --subscription "${CLASSIC_SUBSCRIPTION_NAME}" \
    --resource-type "Microsoft.Web/sites" \
    --query "[?name=='${resource_name}'] | [0].[name,resourceGroup,kind,properties.state]" \
    --output tsv
}

run_old_stack_action() {
  local action="${1}"
  local k8s_name old_base resource_name details app_name resource_group kind state kind_lc state_lc
  local -a app_cli

  [[ -n "${CLASSIC_SUBSCRIPTION_NAME:-}" ]] || fail "CLASSIC_SUBSCRIPTION_NAME is required for ${action}"

  while IFS='|' read -r k8s_name old_base; do
    [[ -n "${k8s_name}" && -n "${old_base}" ]] || continue

    resource_name="$(old_stack_resource_name "${old_base}")"
    log "Resolving old-stack resource '${resource_name}' for K8s service '${k8s_name}'"

    details="$(lookup_old_stack_resource "${resource_name}")"
    [[ -n "${details}" ]] || fail "Could not find old-stack App Service or Function App '${resource_name}' in subscription '${CLASSIC_SUBSCRIPTION_NAME}'"

    IFS=$'\t' read -r app_name resource_group kind state <<<"${details}"
    kind_lc="$(lowercase "${kind}")"
    state_lc="$(lowercase "${state:-unknown}")"

    if [[ "${kind_lc}" == *functionapp* ]]; then
      app_cli=(az functionapp)
    else
      app_cli=(az webapp)
    fi

    case "${action}" in
      stop-old-stack)
        if [[ "${state_lc}" == "stopped" ]]; then
          log "Old-stack resource '${app_name}' is already stopped"
        else
          log "Stopping old-stack resource '${app_name}' in resource group '${resource_group}'"
          run_cmd "${app_cli[@]}" stop \
            --name "${app_name}" \
            --resource-group "${resource_group}" \
            --subscription "${CLASSIC_SUBSCRIPTION_NAME}"
        fi
        ;;
      start-old-stack)
        if [[ "${state_lc}" == "running" ]]; then
          log "Old-stack resource '${app_name}' is already running"
        else
          log "Starting old-stack resource '${app_name}' in resource group '${resource_group}'"
          run_cmd "${app_cli[@]}" start \
            --name "${app_name}" \
            --resource-group "${resource_group}" \
            --subscription "${CLASSIC_SUBSCRIPTION_NAME}"
        fi
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
  local k8s_name old_base workload_kind

  while IFS='|' read -r k8s_name old_base; do
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
        fail "Refusing to suspend Deployment '${k8s_name}' because the previous replica count cannot be restored safely"
        ;;
      unsuspend-k8s:deployment.apps)
        log "Deployment '${k8s_name}' has no suspend flag; leaving it unchanged"
        ;;
      *)
        fail "Unsupported K8s action '${action}' for workload kind '${workload_kind}'"
        ;;
    esac
  done < <(target_mappings)
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
    run_k8s_action "${ACTION}"
    ;;
esac
