#!/bin/bash

set -x

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

# Check for existing group
result="$(OBJECT_NAME="${GROUP_NAME}" OBJECT_TYPE=group "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh")"
if [[ $? -eq 0 ]]; then
  echo "${result}"
  exit 0
fi

# Parse owner object IDs
declare -a ownerObjectIds
if [[ -n "${GROUP_OWNER_OBJECT_IDS}" ]]; then
  while IFS=',' read -ra objectId; do
    ownerObjectIds+=("${objectId}")
  done <<<"${GROUP_OWNER_OBJECT_IDS}"
fi

# Include servicePrincipalId as owner (if set), which is set when addSpnToEnvironment: true
[[ -n "${servicePrincipalId}" ]] && ownerObjectIds+=("${servicePrincipalId}")

# Compile owners
ownersJson=
prefix='https://graph.microsoft.com/v1.0/directoryObjects/'
for i in "${!ownerObjectIds[@]}"; do
  oid="${ownerObjectIds[i]}"
  ownersJson="${ownersJson}\"${prefix}${oid}\""
  (( i < ${#ownerObjectIds[@]} - 1 )) && ownersJson="${ownersJson},\n    "
done

read -r -d '' groupJson <<EOF
{
  "displayName": "${GROUP_NAME}",
  "description": "${GROUP_DESCRIPTION}",
  "securityEnabled": true,
  "mailEnabled": false,
  "isAssignableToRole": true,
  "mailNickname": "${GROUP_NAME}",
  "owners@odata.bind": [
    ${ownersJson}
  ]
}
EOF

# Create the group
groupResult="$(curl -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "${groupJson}" "https://graph.microsoft.com/v1.0/groups")"
[[ $? -ne 0 ]] && exit 1
[[ "$(jq -r '.error.code' <<<"${groupResult}")" == "null" ]] || exit 1
objectId="$(echo "${groupResult}" | jq -r '.id')"
echo "##vso[task.setvariable variable=objectId;isOutput=true]${objectId}"

# Now wait for the group to consistently appear (i.e. propagate)
max_attempts=10
successful=0
attempt=0
wait=2

while (( attempt < max_attempts )); do
  (( attempt++ ))

  result="$(curl -w '%{http_code}' -s -o /dev/null -H "Authorization: Bearer ${TOKEN}" "https://graph.microsoft.com/v1.0/groups/${objectId}")"
  if [[ "${result}" == "200" ]]; then
    (( successful++ ))
    (( successful == 5 )) && exit 0
    wait=2
    sleep 5
  else
    successful=0
    sleep $wait
    (( wait*=2 ))
    (( wait > 60 )) && wait=60
  fi
done

exit 1

# vim: set ts=2 sts=2 sw=2 et:
