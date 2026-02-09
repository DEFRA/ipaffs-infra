#!/bin/bash

set -eux

DIR="$(cd "$(dirname $0)" && pwd)"

deploymentOutput() {
  az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --subscription "${SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query properties.outputs.${1}.value \
    -o tsv
}

valueToSet="$(deploymentOutput "${2}")"
"${DIR}"/update-group-variable.sh "${1}" "${valueToSet}"

# vim: set ts=2 sts=2 sw=2 et:
