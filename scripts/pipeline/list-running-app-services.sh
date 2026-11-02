#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: list-running-app-services.sh

Prints the running App Services and Function Apps in a subscription as
resourceGroup/appName lines, ready for disable-app-services/<env>-decommission-apps.txt.
Read only. Review the output before committing it.

Environment:
  SUBSCRIPTION_NAME        Subscription to list, e.g. AZR-TST.
  RESOURCE_GROUP_PATTERN   Case insensitive regex for resource groups;
                           defaults to IMP.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    usage
    fail "Unexpected argument '${1}'"
    ;;
esac

[[ -n "${SUBSCRIPTION_NAME:-}" ]] || fail "SUBSCRIPTION_NAME is required"
RESOURCE_GROUP_PATTERN="${RESOURCE_GROUP_PATTERN:-IMP}"

cat <<HEADER
# Running App Services and Function Apps in ${SUBSCRIPTION_NAME}
# The pipeline stops these on disable and starts them on recover
# Generated $(date -u +"%Y-%m-%d") by scripts/pipeline/list-running-app-services.sh
# One resourceGroup/appName per line
HEADER

{
  az webapp list --subscription "${SUBSCRIPTION_NAME}" --output json
  az functionapp list --subscription "${SUBSCRIPTION_NAME}" --output json
} | jq -rs --arg pattern "${RESOURCE_GROUP_PATTERN}" \
  'add | unique_by(.id)[] | select(.state == "Running" and (.resourceGroup | test($pattern; "i"))) | .resourceGroup + "/" + .name' \
  | sort -f
