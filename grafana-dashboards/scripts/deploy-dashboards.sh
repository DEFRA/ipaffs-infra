#!/bin/bash
# deploy-dashboards.sh
#
# Deploys Grafana dashboard JSON files to ONE environment's Grafana instance,
# pointing each dashboard's datasource template variables at that environment's
# own Prometheus and Azure Monitor datasources.
#
# This is the single source of truth for the deploy logic: the
# deploy-grafana-dashboards.yaml pipeline stage calls it, and it can be run
# locally (e.g. to test a dashboard before committing) so what you test locally
# is exactly what CI runs.
#
# Required environment variables:
#   GRAFANA_NAME     – Azure Managed Grafana resource name
#   RESOURCE_GROUP   – Resource group of the Grafana instance
#   ENVIRONMENT      – Environment label, e.g. "DEV" (used in datasource names)
#
# Optional environment variables:
#   DASHBOARD_FILES  – space-separated explicit JSON files to deploy. When set,
#                      only these are deployed (handy for testing a single
#                      dashboard). When unset, deploys every *.json under
#                        <DASHBOARDS_ROOT>
#   DASHBOARDS_ROOT  – default: grafana-dashboards/dashboards
#   PROM_DS_NAME     – default: "Prometheus - <ENV>"
#   AZMON_DS_NAME    – default: "Azure Monitor - <ENV>"
#   DRY_RUN          – "true" to print what would happen without deploying
#
# A datasource template variable's *value* is the datasource UID (panels
# reference it as uid: "${var}"), so the real UID is injected, not the name.
# UIDs are resolved from the live Grafana; if a datasource does not exist yet
# (run configure-grafana.sh first) the name is used as a fallback.

set -euo pipefail

GRAFANA_NAME="${GRAFANA_NAME:?GRAFANA_NAME must be set}"
RESOURCE_GROUP="${RESOURCE_GROUP:?RESOURCE_GROUP must be set}"
ENVIRONMENT="${ENVIRONMENT:?ENVIRONMENT must be set}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?SUBSCRIPTION_ID must be set}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:?SUBSCRIPTION_NAME must be set}"

ENV_UPPER="${ENVIRONMENT^^}"
SCRIPTS_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
DASHBOARDS_ROOT="${SCRIPTS_DIR}"/../grafana-dashboards/dashboards
PROM_DS_NAME="${PROM_DS_NAME:-Prometheus}"
AZMON_DS_NAME="${AZMON_DS_NAME:-Azure Monitor}"
DRY_RUN="${DRY_RUN:-false}"

az extension add --name amg --yes --upgrade --only-show-errors

# ── Resolve this env's datasource UIDs (once) ──────────────────────────────
resolve_uid() {
  az grafana data-source show \
    --name "${GRAFANA_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --data-source "$1" \
    --query uid --output tsv 2>/dev/null || true
}
PROM_DS_UID="$(resolve_uid "${PROM_DS_NAME}")";   PROM_DS_UID="${PROM_DS_UID:-${PROM_DS_NAME}}"
AZMON_DS_UID="$(resolve_uid "${AZMON_DS_NAME}")"; AZMON_DS_UID="${AZMON_DS_UID:-${AZMON_DS_NAME}}"

echo "Grafana:          ${GRAFANA_NAME} (rg=${RESOURCE_GROUP}, env=${ENV_UPPER})"
echo "Prometheus DS:    ${PROM_DS_NAME} (uid=${PROM_DS_UID})"
echo "Azure Monitor DS: ${AZMON_DS_NAME} (uid=${AZMON_DS_UID})"
[[ "${DRY_RUN}" == "true" ]] && echo "(DRY_RUN: no changes will be made)"
echo ""

# ── Deploy one dashboard ───────────────────────────────────────────────────
ERRORS=0
deploy_dashboard() {
  local file="$1"
  local uid title definition

  uid=$(jq -r '.uid' "${file}")
  title=$(jq -r '.title' "${file}")

  # Point each datasource template variable at this env's datasource, matched by
  # plugin type (.query). Variables of other types — and dashboards that only
  # use one datasource — are left untouched. The repo source file is never
  # modified (patch is applied in-memory).
  definition=$(jq \
    --arg promName "${PROM_DS_NAME}" --arg promUid "${PROM_DS_UID}" \
    --arg azName "${AZMON_DS_NAME}"  --arg azUid "${AZMON_DS_UID}" \
    --arg subId "${SUBSCRIPTION_ID}" \
    --arg subName "${SUBSCRIPTION_NAME}" \
    '(.templating.list[]
        | select(.type == "datasource" and .query == "prometheus")) |=
        (.current = {selected: true, text: $promName, value: $promUid})
     | (.templating.list[]
        | select(.type == "datasource" and .query == "grafana-azure-monitor-datasource")) |=
        (.current = {selected: true, text: $azName, value: $azUid})
     | (.templating.list[] | select(.name == "subscription")) |=
        (.current = {selected: true, text: $subName, value: $subId})' \
    "${file}")

  echo "Deploying: ${title} (uid=${uid})"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [dry-run] would update ${GRAFANA_NAME}"
    return 0
  fi

  if echo "${definition}" | az grafana dashboard update \
       --name "${GRAFANA_NAME}" \
       --resource-group "${RESOURCE_GROUP}" \
       --definition @- \
       --overwrite \
       --output none; then
    echo "  OK"
  else
    echo "  FAILED: ${file}" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

# ── Build the list of dashboards to deploy ─────────────────────────────────
declare -a files=()
if [[ -n "${DASHBOARD_FILES:-}" ]]; then
  # Explicit list (e.g. testing a single dashboard)
  for f in ${DASHBOARD_FILES}; do
    [[ -f "${f}" ]] || { echo "ERROR: file not found: ${f}" >&2; exit 1; }
    files+=("${f}")
  done
else
  # All dashboard JSON under DASHBOARDS_ROOT (deployed to the selected env).
  while IFS= read -r f; do files+=("${f}"); done \
    < <(find "${DASHBOARDS_ROOT}" -name "*.json" 2>/dev/null | sort)
fi

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No dashboards found to deploy." >&2
  exit 1
fi

# Deploy (no subshell, so the ERROR count survives)
for f in "${files[@]}"; do
  deploy_dashboard "${f}"
done

if [[ "${ERRORS}" -gt 0 ]]; then
  echo "Deploy finished with ${ERRORS} error(s)." >&2
  exit 1
fi
echo "All dashboards deployed successfully."

# vim: set ts=2 sts=2 sw=2 et:
