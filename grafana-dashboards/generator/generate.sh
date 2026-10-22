#!/bin/bash
# generate.sh
#
# Regenerates the layered IPAFFS dashboards (Service Health, Service Drill-down,
# Messaging & Integrations) into grafana-dashboards/dashboards/ from the Python
# sources in this directory. Edit the .py files, run this, commit both.
#
# Usage:
#   bash grafana-dashboards/generator/generate.sh

set -euo pipefail

GENERATOR_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARDS_DIR="${GENERATOR_DIR}/../dashboards"

generate() {
  python3 "${GENERATOR_DIR}/$1" > "${DASHBOARDS_DIR}/$2"
  echo "Generated ${2}"
}

generate health.py IPAFFSServiceHealth.json
generate drilldown.py IPAFFSServiceDrilldown.json
generate messaging.py IPAFFSMessagingIntegrations.json

# vim: set ts=2 sts=2 sw=2 et:
