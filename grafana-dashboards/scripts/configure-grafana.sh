#!/bin/bash
# configure-grafana.sh
#
# Creates / updates the datasources for a SINGLE environment's Grafana
# instance, so the dashboards' template variables (the namespace / datasource
# dropdowns) resolve:
#   1. A Prometheus datasource (MSI auth) pointing at the env's Azure Monitor
#      workspace Prometheus query endpoint.
#   2. An Azure Monitor datasource (MSI auth) for Log Analytics queries.
#
# Must be run with a service connection that has Grafana Admin rights on the
# target Grafana instance (the env's own service connection).
#
# Environment variables (required):
#   GRAFANA_NAME         – Azure Managed Grafana resource name
#   RESOURCE_GROUP       – Resource group of the Grafana instance
#   ENVIRONMENT          – Environment label, e.g. "DEV" (used in datasource names)
#   PROMETHEUS_ENDPOINT  – Prometheus query endpoint URL for this env
#   SUBSCRIPTION_ID      – Subscription ID for this env (Azure Monitor datasource)
#
# The Grafana MI must already hold Monitoring Data Reader on the Prometheus
# workspace and Log Analytics Reader on the Log Analytics workspace for these
# datasources to return data. Those roles are granted manually (out of scope).

set -euo pipefail

GRAFANA_NAME="${GRAFANA_NAME:?GRAFANA_NAME must be set}"
RESOURCE_GROUP="${RESOURCE_GROUP:?RESOURCE_GROUP must be set}"
ENVIRONMENT="${ENVIRONMENT:?ENVIRONMENT must be set}"
PROMETHEUS_ENDPOINT="${PROMETHEUS_ENDPOINT:?PROMETHEUS_ENDPOINT must be set}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?SUBSCRIPTION_ID must be set}"

ENV_UPPER="${ENVIRONMENT^^}"

echo "Configuring datasources in Grafana: ${GRAFANA_NAME} (env: ${ENV_UPPER})"
echo ""

az extension add --name amg --yes --upgrade --only-show-errors

# ── Helper: upsert a datasource ────────────────────────────────────────────
# Uses az grafana data-source update if it exists, create otherwise.
upsert_datasource() {
  local definition_json="$1"
  local ds_name
  ds_name=$(echo "${definition_json}" | jq -r '.name')

  echo "  Upserting datasource: ${ds_name}"

  if az grafana data-source show \
       --name "${GRAFANA_NAME}" \
       --resource-group "${RESOURCE_GROUP}" \
       --data-source "${ds_name}" \
       --output none 2>/dev/null; then
    az grafana data-source update \
      --name "${GRAFANA_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --data-source "${ds_name}" \
      --definition "${definition_json}" \
      --output none
    echo "  Updated: ${ds_name}"
  else
    az grafana data-source create \
      --name "${GRAFANA_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --definition "${definition_json}" \
      --output none
    echo "  Created: ${ds_name}"
  fi
}

# ── Prometheus datasource ──────────────────────────────────────────────────
# Azure Managed Grafana uses the instance's MSI to authenticate against the
# Azure Monitor workspace Prometheus endpoint.
prometheus_ds=$(jq -n \
  --arg name "Prometheus" \
  --arg url "${PROMETHEUS_ENDPOINT}" \
  '{
    name: $name,
    type: "prometheus",
    access: "proxy",
    url: $url,
    isDefault: true,
    jsonData: {
      httpMethod: "POST",
      azureCredentials: { authType: "msi" }
    }
  }')
upsert_datasource "${prometheus_ds}"

# ── Azure Monitor datasource (Log Analytics + metrics) ─────────────────────
# The native grafana-azure-monitor-datasource plugin uses MSI and supports
# Log Analytics queries given the Grafana MI has the reader role.
azure_monitor_ds=$(jq -n \
  --arg name "Azure Monitor" \
  --arg sub "${SUBSCRIPTION_ID}" \
  '{
    name: $name,
    type: "grafana-azure-monitor-datasource",
    access: "proxy",
    isDefault: false,
    jsonData: {
      azureAuthType: "msi",
      subscriptionId: $sub,
      logAnalyticsDefaultWorkspace: ""
    }
  }')
upsert_datasource "${azure_monitor_ds}"

echo ""
echo "Grafana datasource configuration complete for ${ENV_UPPER}."

# vim: set ts=2 sts=2 sw=2 et:
