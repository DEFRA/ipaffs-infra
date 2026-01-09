#!/bin/bash

set -eux

# Get the ID of the library variable group
groupId="$(az pipelines variable-group list \
  --org "${ADO_ORG_URL}" \
  --project "${ADO_PROJECT}" \
  --group-name "${ADO_GROUP_NAME}" \
  --query '[0].id' \
  -o tsv)"

getGroupVariable() {
  az pipelines variable-group variable list \
    --org "${ADO_ORG_URL}" \
    --project "${ADO_PROJECT}" \
    --id "${groupId}" \
    --query "${1}.value" \
    -o tsv
}

createGroupVariable() {
   az pipelines variable-group variable create \
    --org "${ADO_ORG_URL}" \
    --project "${ADO_PROJECT}" \
    --id "${groupId}" \
    --name "${1}" \
    --value "${2}"
}

updateGroupVariable() {
   az pipelines variable-group variable update \
    --org "${ADO_ORG_URL}" \
    --project "${ADO_PROJECT}" \
    --id "${groupId}" \
    --name "${1}" \
    --value "${2}"
}

# Get existing value
if [[ "$(getGroupVariable "${1}")" != "" ]]; then
  # Update library group variable
  updateGroupVariable "${1}" "${2}"
else
  # Create new library variable
  createGroupVariable "${1}" "${2}"
fi

# vim: set ts=2 sts=2 sw=2 et:
