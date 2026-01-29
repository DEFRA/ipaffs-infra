#!/bin/bash

## NOTE: Currently only users are supported as group members

set -x

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

# Check for existing group
groupObjectId="$(OBJECT_NAME="${GROUP_NAME}" OBJECT_TYPE=group "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh" -o none)"
if [[ $? -ne 0 ]]; then
  echo "Group not found: ${GROUP_NAME}" >&2
  exit 1
fi

# Parse member object IDs
declare -a memberUPNs
if [[ -n "${GROUP_MEMBERS}" ]]; then
  cleanMembers="$(echo "${GROUP_MEMBERS}" | tr -d '\n')"
  IFS=' ' read -ra memberUPNs <<<"${cleanMembers}"
fi

# Compile members
membersJson=
prefix='https://graph.microsoft.com/v1.0/servicePrincipals/'
for i in "${!memberUPNs[@]}"; do
  upn="$(echo "${memberUPNs[i]}" | awk '{$1=$1};1')"
  [[ "${upn}" == "" ]] && continue
  oid="$(OBJECT_NAME="${upn}" OBJECT_TYPE=user "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh" -o plain)"
  if [[ $? -ne 0 ]]; then
    echo "User not found: ${upn}" >&2
    exit 1
  fi

  membersJson="${membersJson}\"${prefix}${oid}\""
  (( i < ${#memberUPNs[@]} - 1 )) && membersJson="${membersJson}, "
done

read -r -d '' groupJson <<EOF
{
  "members@odata.bind": [
    ${membersJson}
  ]
}
EOF

echo "${groupJson}"
exit 0

# Update the group
groupResult="$(curl -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "${groupJson}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}")"
[[ $? -ne 0 ]] && exit 1
[[ "$(jq -r '.error.code' <<<"${groupResult}")" == "null" ]] || exit 1

exit 0

# vim: set ts=2 sts=2 sw=2 et:
