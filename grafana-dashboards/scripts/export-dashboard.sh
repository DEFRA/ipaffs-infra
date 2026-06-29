#!/bin/bash
# export-dashboard.sh
#
# Exports dashboards from an existing Azure Managed Grafana instance and saves
# them to grafana-dashboards/dashboards/ for version control.
#
# Run this once to seed the repo from a manually-created dashboard, then
# commit the result. The pipeline deploys from these stored JSON files.
#
# Usage (examples):
#
#   # Export ALL non-provisioned dashboards to dashboards/
#   GRAFANA_NAME=DEVIMPINFGA1401 \
#   RESOURCE_GROUP=DEVIMPINFRG1401 \
#   bash grafana-dashboards/scripts/export-dashboard.sh
#
#   # Export one specific dashboard by UID
#   GRAFANA_NAME=DEVIMPINFGA1401 \
#   RESOURCE_GROUP=DEVIMPINFRG1401 \
#   DASHBOARD_UID=ipaffs-overview-v1 \
#   bash grafana-dashboards/scripts/export-dashboard.sh
#
#   # Export one specific dashboard by TITLE (uid is looked up for you)
#   GRAFANA_NAME=DEVIMPINFGA1401 \
#   RESOURCE_GROUP=DEVIMPINFRG1401 \
#   DASHBOARD_TITLE=IPAFFS_stack \
#   bash grafana-dashboards/scripts/export-dashboard.sh
#
# Prerequisites:
#   az login (or run inside an AzureCLI@2 pipeline task)
#   az extension add --name amg

set -euo pipefail

GRAFANA_NAME="${GRAFANA_NAME:?GRAFANA_NAME must be set}"
RESOURCE_GROUP="${RESOURCE_GROUP:?RESOURCE_GROUP must be set}"
SCRIPTS_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
OUTPUT_DIR="${SCRIPTS_DIR}"/../grafana-dashboards/dashboards
DASHBOARD_UID="${DASHBOARD_UID:-}"      # export this uid; empty + no title => export all
DASHBOARD_TITLE="${DASHBOARD_TITLE:-}"  # resolve uid from this title (ignored if UID set)

mkdir -p "${OUTPUT_DIR}"

echo "Installing Azure Managed Grafana CLI extension (idempotent)..."
az extension add --name amg --yes --upgrade --only-show-errors

# ── Resolve uid from title ─────────────────────────────────────────────────
# Grafana dashboards are addressed by uid, but a title is easier to remember.
# When DASHBOARD_TITLE is given (and DASHBOARD_UID is not), look the uid up.
# Titles are not guaranteed unique, so we fail clearly on 0 or multiple matches.
if [[ -z "${DASHBOARD_UID}" && -n "${DASHBOARD_TITLE}" ]]; then
  echo "Resolving uid for dashboard titled '${DASHBOARD_TITLE}'..."

  matches=$(az grafana dashboard list \
    --name "${GRAFANA_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --output json \
    | jq -c --arg t "${DASHBOARD_TITLE}" \
        '[.[] | select(.type == "dash-db" and .title == $t) | .uid]')

  match_count=$(echo "${matches}" | jq 'length')

  if [[ "${match_count}" -eq 0 ]]; then
    echo "ERROR: no dashboard titled '${DASHBOARD_TITLE}' found in ${GRAFANA_NAME}." >&2
    echo "       Check the title, or set DASHBOARD_UID directly." >&2
    exit 1
  elif [[ "${match_count}" -gt 1 ]]; then
    echo "ERROR: ${match_count} dashboards share the title '${DASHBOARD_TITLE}':" >&2
    echo "${matches}" | jq -r '.[] | "         uid=\(.)"' >&2
    echo "       Disambiguate by setting DASHBOARD_UID to the one you want." >&2
    exit 1
  fi

  DASHBOARD_UID=$(echo "${matches}" | jq -r '.[0]')
  echo "Resolved '${DASHBOARD_TITLE}' -> uid=${DASHBOARD_UID}"
fi

# ── Helper: sanitise a dashboard JSON for storage ──────────────────────────
# Grafana internal fields that must be stripped before re-importing:
#   id         – numeric, assigned by the Grafana DB; causes conflicts on import
#   version    – auto-incremented; Grafana assigns on import
#   folderId   – numeric, not portable across instances
#   folderUid  – omit so the pipeline can place the dashboard in the right folder
#   meta       – server-side metadata, not part of the dashboard model
#
# uid is KEPT: it is the portable identifier we use for idempotent deploys.
sanitise() {
  local raw="$1"

  # az grafana dashboard show wraps the definition under a "dashboard" key
  # in some CLI versions. Unwrap if needed.
  if echo "${raw}" | jq -e '.dashboard' >/dev/null 2>&1; then
    raw=$(echo "${raw}" | jq '.dashboard')
  fi

  echo "${raw}" | jq 'del(.id, .version, .folderId, .folderUid, .meta)'
}

# ── Export one dashboard ───────────────────────────────────────────────────
export_one() {
  local uid="$1"
  local title="$2"

  # File is named after the dashboard TITLE (not the uid). Titles can contain
  # spaces / punctuation, so slugify to a safe filename: whitespace -> "_",
  # drop anything that is not alphanumeric / dot / underscore / hyphen. Fall
  # back to the uid if the title slugifies to an empty string.
  local safe_title
  safe_title=$(printf '%s' "${title}" \
    | sed -e 's/[[:space:]]\+/_/g' -e 's/[^[:alnum:]._-]//g')
  [[ -z "${safe_title}" ]] && safe_title="${uid}"
  local out_file="${OUTPUT_DIR}/${safe_title}.json"

  echo "  Exporting: ${title} (uid=${uid})"

  local raw
  raw=$(az grafana dashboard show \
    --name "${GRAFANA_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --dashboard "${uid}" \
    --output json)

  local sanitised
  sanitised=$(sanitise "${raw}")

  echo "${sanitised}" | jq . > "${out_file}"
  echo "  Saved: ${out_file}"
}

# ── Main ───────────────────────────────────────────────────────────────────
if [[ -n "${DASHBOARD_UID}" ]]; then
  echo "Exporting dashboard uid=${DASHBOARD_UID} from ${GRAFANA_NAME}..."
  title=$(az grafana dashboard show \
    --name "${GRAFANA_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --dashboard "${DASHBOARD_UID}" \
    --output json \
    | jq -r '.title // .dashboard.title // "unknown"')
  export_one "${DASHBOARD_UID}" "${title}"
else
  echo "Exporting all dashboards from ${GRAFANA_NAME}..."

  # List returns: [{uid, title, type, ...}]
  # Filter out provisioned dashboards (type == "dash-folder") and built-ins.
  dashboards=$(az grafana dashboard list \
    --name "${GRAFANA_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --output json \
    | jq -c '[.[] | select(.type == "dash-db")]')

  count=$(echo "${dashboards}" | jq 'length')
  if [[ "${count}" -eq 0 ]]; then
    echo "No dashboards found in ${GRAFANA_NAME}."
    exit 0
  fi

  echo "Found ${count} dashboard(s)."
  echo ""

  echo "${dashboards}" | jq -c '.[]' | while read -r dash; do
    uid=$(echo "${dash}" | jq -r '.uid')
    title=$(echo "${dash}" | jq -r '.title')
    export_one "${uid}" "${title}"
  done
fi

echo ""
echo "Export complete. Review the files in ${OUTPUT_DIR}, then commit them:"
echo "  git add ${OUTPUT_DIR}"
echo "  git commit -m 'Export Grafana dashboards from ${GRAFANA_NAME}'"

# vim: set ts=2 sts=2 sw=2 et:
