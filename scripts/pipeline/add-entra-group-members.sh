#!/bin/bash

set -x

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

# Check for existing group
groupObjectId=
if [[ -n "${GROUP_ID}" ]]; then
  groupObjectId="${GROUP_ID}"
else
  groupObjectId="$(OBJECT_NAME="${GROUP_NAME}" OBJECT_TYPE=group "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh" -o oid)"
  if [[ $? -ne 0 ]]; then
    echo "Group not found: ${GROUP_NAME}" >&2
    exit 1
  fi
fi

# Parse member URIs
declare -a memberIds
if [[ -n "${GROUP_MEMBERS}" ]]; then
  cleanMembers="$(echo "${GROUP_MEMBERS}" | tr -d '\n')"
  IFS=' ' read -ra memberIds <<<"${cleanMembers}"
fi

# Compile members
membersJson=
for i in "${!memberIds[@]}"; do
  oid="$(echo "${memberIds[i]}" | awk '{$1=$1};1')"
  membersJson="${membersJson}\"https://graph.microsoft.com/v1.0/directoryObjects/${oid}\""
  (( i < ${#memberIds[@]} - 1 )) && membersJson="${membersJson}, "
done

if [[ "${membersJson}" == "" ]]; then
  echo "No members to be added" >&2
  exit 0
fi

read -r -d '' groupJson <<EOF
{
  "members@odata.bind": [
    ${membersJson}
  ]
}
EOF

# Update the group
groupResult="$(curl -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "${groupJson}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}")"
[[ $? -ne 0 ]] && exit 1
errorCode="$(jq -r '.error.code' <<<"${groupResult}")"
[[ "${errorCode}" == "null" ]] || [[ "${errorCode}" == "" ]] || exit 1

exit 0

# vim: set ts=2 sts=2 sw=2 et:
