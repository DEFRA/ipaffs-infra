#!/bin/bash

## NOTE: Currently only service principals are supported as group owners

set -x

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

# Parse owner object IDs
declare -a ownerPrincipalNames
if [[ -n "${GROUP_OWNERS}" ]]; then
  cleanOwners="$(echo "${GROUP_OWNERS}" | tr -d '\n')"
  IFS=' ' read -ra ownerPrincipalNames <<<"${cleanOwners}"
fi

# Include servicePrincipalId as owner (if set), which is set when addSpnToEnvironment: true
[[ -n "${servicePrincipalId}" ]] && ownerObjectIds+=("${servicePrincipalId}")

# Compile owners
ownersJson=
prefix='https://graph.microsoft.com/v1.0/servicePrincipals/'
for i in "${!ownerPrincipalNames[@]}"; do
  displayName="$(echo "${ownerPrincipalNames[i]}" | awk '{$1=$1};1')"
  [[ "${displayName}" == "" ]] && continue
  oid="$(OBJECT_NAME="${displayName}" OBJECT_TYPE=servicePrincipal "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh" -o plain)"
  ownersJson="${ownersJson}\"${prefix}${oid}\""
  (( i < ${#ownerPrincipalNames[@]} - 1 )) && ownersJson="${ownersJson}, "
done

read -r -d '' groupJson <<EOF
{
  "displayName": "${GROUP_NAME}",
  "description": "${GROUP_DESCRIPTION}",
  "securityEnabled": true,
  "mailEnabled": false,
  "isAssignableToRole": ${GROUP_IS_ROLE_ASSIGNABLE:-false},
  "mailNickname": "${GROUP_NAME}",
  "owners@odata.bind": [
    ${ownersJson}
  ]
}
EOF

# Check for existing group
objectId="$(OBJECT_NAME="${GROUP_NAME}" OBJECT_TYPE=group "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh" -o plain)"
if [[ $? -eq 0 ]]; then
  # Update the group
  groupResult="$(curl -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "${groupJson}" "https://graph.microsoft.com/v1.0/groups/${objectId}")"
  [[ $? -ne 0 ]] && exit 1
  [[ "$(jq -r '.error.code' <<<"${groupResult}")" == "null" ]] || exit 1
else
  # Create the group
  groupResult="$(curl -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "${groupJson}" "https://graph.microsoft.com/v1.0/groups")"
  [[ $? -ne 0 ]] && exit 1
  [[ "$(jq -r '.error.code' <<<"${groupResult}")" == "null" ]] || exit 1
  objectId="$(echo "${groupResult}" | jq -r '.id')"
fi

set +x
echo "##vso[task.setvariable variable=displayName;isOutput=true]${GROUP_NAME}"
echo "##vso[task.setvariable variable=objectId;isOutput=true]${objectId}"

# Now wait for the group to consistently appear (i.e. propagate)
set -x
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
