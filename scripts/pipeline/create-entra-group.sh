#!/bin/bash

## create-entra-group.sh
##
## Creates an Entra security group and ensures it has desired ownership to enable ongoing group management.
## For existing groups, this script is idempotent and will attempt to locate the group by its display name,
## and will update the group properties.
##
## Optional script arguments:
## -u  Update-only flag, do not create a new group when specified
##
## Required environment variables:
## GROUP_NAME        - The display name of a group to locate and add members
## GROUP_DESCRIPTION - The object ID of a group to add members
##
## Optional environment variables:
## GROUP_OWNER_OBJECT_IDS   - Set of object IDs for principals that will own the group. This is only set
##                            at group creation time, and can include the calling principal (the script
##                            will gracefully handle known API issues around automagic ownership).
##
## ADO Variable Outputs:
## displayName - The display name of the group, as provided via the GROUP_NAME environment variable.
## objectId    - The object ID of the group that was created, or the existing group that was updated.

set -x

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"

updateOnly=

while getopts "u" opt; do
  case $opt in
    u)
      updateOnly=1
      ;;
  esac
done

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

# Parse the calling principal's object ID from the token claims
principalId="$(echo "${TOKEN}" | cut -d. -f2 | base64 -d | jq -r '.oid')"

# Parse owner object IDs
declare -a ownerObjectIds
if [[ -n "${GROUP_OWNER_OBJECT_IDS}" ]]; then
  cleanOwners="$(echo "${GROUP_OWNER_OBJECT_IDS}" | tr -d '\n')"
  IFS=' ' read -ra ownerObjectIds <<<"${cleanOwners}"
fi

groupJson() {
  # Compile owners
  ownersJson=
  if [[ "${operation}" == "create" ]]; then
    prefix='https://graph.microsoft.com/v1.0/directoryObjects/'
    for i in "${!ownerObjectIds[@]}"; do
      oid="${ownerObjectIds[i]}"
      ownersJson="${ownersJson}\"${prefix}${oid}\", "
    done
  fi

  # Trim trailing comma/space from json array
  (( ${#ownersJson} > 2 )) && ownersJson="${ownersJson::-2}"

  # Determine whether to include owners property
  ownersProperty=
  [[ "${ownersJson}" = *[!\ ]* ]] && read -r -d '' ownersProperty <<EOF
,
   "owners@odata.bind": [
     ${ownersJson}
   ]
EOF

  # Output group manifest
  cat <<EOF
{
  "displayName": "${GROUP_NAME}",
  "description": "${GROUP_DESCRIPTION}",
  "securityEnabled": true,
  "mailEnabled": false,
  "mailNickname": "${GROUP_NAME}"${ownersProperty}
}
EOF
}

# Check for existing group
operation=create
objectId=
if [[ -n "${GROUP_ID}" ]]; then
  operation=update
  objectId="${GROUP_ID}"
else
  result="$(OBJECT_NAME="${GROUP_NAME}" OBJECT_TYPE=group "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh" -o oid)"
  if [[ $? -eq 0 ]]; then
    operation=update
    objectId="${result}"
  fi
fi

if [[ -n "${updateOnly}" ]] && [[ "${operation}" == "create" ]]; then
  echo "update-only option was specified but existing group could not be identified" >&2
  exit 1
fi

if [[ "${operation}" == "update" ]] && [[ -z "${objectId}" ]]; then
  echo "Wanted to update an existing group but could not determine group object ID" >&2
  exit 1
fi

case "${operation}" in
  create)
    groupResult="$(curl -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "$(groupJson)" "https://graph.microsoft.com/v1.0/groups")"
    [[ $? -ne 0 ]] && exit 1
    errorCode="$(jq -r '.error.code' <<<"${groupResult}")"

    if [[ "${errorCode}" != "null" ]] && [[ "${errorCode}" != "" ]]; then
      if [[ "${groupResult}" =~ "One or more added object references already exist" ]]; then
        # Retry without calling principal as owner, since the API silently prepends it
        for i in "${!ownerObjectIds[@]}"; do
          [[ "${ownerObjectIds[i]}" == "${principalId}" ]] && unset ownerObjectIds[i]
        done
        groupResult="$(curl -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "$(groupJson)" "https://graph.microsoft.com/v1.0/groups")"
        [[ $? -ne 0 ]] && exit 1
        errorCode="$(jq -r '.error.code' <<<"${groupResult}")"
        [[ "${errorCode}" == "null" ]] || [[ "${errorCode}" == "" ]] || exit 1
      else
        exit 1
      fi
    fi
    objectId="$(echo "${groupResult}" | jq -r '.id')"
    ;;

  update)
    groupResult="$(curl -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "$(groupJson)" "https://graph.microsoft.com/v1.0/groups/${objectId}")"
    [[ $? -ne 0 ]] && exit 1
    errorCode="$(jq -r '.error.code' <<<"${groupResult}")"

    if [[ "${errorCode}" != "null" ]] && [[ "${errorCode}" != "" ]]; then
      if [[ "${groupResult}" =~ "One or more added object references already exist" ]]; then
        # Retry without calling principal as owner, since the API silently prepends it
        for i in "${!ownerObjectIds[@]}"; do
          [[ "${ownerObjectIds[i]}" == "${principalId}" ]] && unset ownerObjectIds[i]
        done
        groupResult="$(curl -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "$(groupJson)" "https://graph.microsoft.com/v1.0/groups/${objectId}")"
        [[ $? -ne 0 ]] && exit 1
        errorCode="$(jq -r '.error.code' <<<"${groupResult}")"
        [[ "${errorCode}" == "null" ]] || [[ "${errorCode}" == "" ]] || exit 1
      else
        exit 1
      fi
    fi
    ;;
esac

set +x
echo "##vso[task.setvariable variable=displayName;isOutput=true]${GROUP_NAME}"
echo "##vso[task.setvariable variable=objectId;isOutput=true]${objectId}"

if [[ "${operation}" == "create" ]]; then
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
fi

exit 0

# vim: set ts=2 sts=2 sw=2 et:
