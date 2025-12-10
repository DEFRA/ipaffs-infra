#!/bin/bash

set -x

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

# Check for existing group
GROUP_SEARCH_RESULT="$(curl -H "Authorization: Bearer ${TOKEN}" "https://graph.microsoft.com/v1.0/groups?\$filter=displayName+eq+'${GROUP_NAME}'")"
[[ $? -ne 0 ]] && exit 1
[[ "$(jq -r '.error.code' <<<"${GROUP_SEARCH_RESULT}")" == "null" ]] || exit 1
GROUP_ID="$(jq -r '.value[0].id' <<<"${GROUP_SEARCH_RESULT}")"
if [[ -n "${GROUP_ID}" ]] && [[ "${GROUP_ID}" != "null" ]]; then
  echo "##vso[task.setvariable variable=groupId]${GROUP_ID}"
  exit 0
fi

[[ -z "${GROUP_OWNER_OBJECT_ID}" ]] && [[ -n "${servicePrincipalId}" ]] && \
  GROUP_OWNER_OBJECT_ID="${servicePrincipalId}"

read -r -d '' GROUP_JSON <<EOF
{
  "displayName": "${GROUP_NAME}",
  "description": "${GROUP_DESCRIPTION}",
  "securityEnabled": true,
  "mailEnabled": false,
  "isAssignableToRole": true,
  "mailNickname": "${GROUP_NAME}",
  "owners@odata.bind": [
    "https://graph.microsoft.com/v1.0/directoryObjects/${GROUP_OWNER_OBJECT_ID}"
  ]
}
EOF

# Create the group
GROUP_RESULT="$(curl -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "${GROUP_JSON}" "https://graph.microsoft.com/v1.0/groups")"
[[ $? -ne 0 ]] && exit 1
[[ "$(jq -r '.error.code' <<<"${GROUP_RESULT}")" == "null" ]] || exit 1
GROUP_ID="$(echo "${GROUP_RESULT}" | jq -r '.id')"
echo "##vso[task.setvariable variable=groupId]${GROUP_ID}"

# Now wait for the group to consistently appear (i.e. propagate)
max_attempts=10
successful=0
attempt=0
wait=2

while (( attempt < max_attempts )); do
  (( attempt++ ))

  result="$(curl -w '%{http_code}' -s -o /dev/null -H "Authorization: Bearer ${TOKEN}" "https://graph.microsoft.com/v1.0/groups/${GROUP_ID}")"
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
