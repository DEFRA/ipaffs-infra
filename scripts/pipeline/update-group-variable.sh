#!/bin/bash

set -x

# Get the ID of the library variable group
groupId="$(az pipelines variable-group list \
  --org "${ADO_ORG_URL}" \
  --project "${ADO_PROJECT}" \
  --group-name "${ADO_GROUP_NAME}" \
  --query '[0].id' \
  -o tsv)"

deploymentOutput() {
  az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query properties.outputs.${1}.value \
    -o tsv
}

updateGroupVariable() {
  az pipelines variable-group variable update \
  --org "${ADO_ORG_URL}" \
  --project "${ADO_PROJECT}" \
    --id "${groupId}" \
    --name "${1}" \
    --value "${2}"
}

# Update library group variable
updateGroupVariable "${1}" "$(deploymentOutput "${2}")"

# vim: set ts=2 sts=2 sw=2 et:
