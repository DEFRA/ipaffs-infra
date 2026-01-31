#!/bin/bash

set -x

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"
source "${SCRIPTS_DIR}/pipeline/_common.sh"

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

membersResult="$(curl -H "Authorization: Bearer ${TOKEN}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}/members")"
[[ $? -ne 0 ]] && exit 1
errorCode="$(jq -r '.error.code' <<<"${membersResult}")"
[[ "${errorCode}" == "null" ]] || [[ "${errorCode}" == "" ]] || exit 1

# Parse existing group member object IDs
mapfile -t existingGroupMembers < <(echo "${membersResult}" | jq -r '.value[].id')

# Parse desired member object IDs
declare -a desiredGroupMembers
if [[ -n "${GROUP_MEMBERS}" ]]; then
  cleanMembers="$(echo "${GROUP_MEMBERS}" | tr -d '\n')"
  IFS=' ' read -ra desiredGroupMembers <<<"${cleanMembers}"
fi

# Determine members to add
membersToAdd=
for i in "${!desiredGroupMembers[@]}"; do
  for j in "${!existingGroupMembers[@]}"; do
    [[ "${desiredGroupMembers[i]}" == "${existingGroupMembers[j]}" ]] && continue 2
  done

  membersToAdd="${membersToAdd} ${desiredGroupMembers[i]}"
done

# Determine members to remove
membersToRemove=
for i in "${!existingGroupMembers[@]}"; do
  for j in "${!desiredGroupMembers[@]}"; do
    [[ "${existingGroupMembers[i]}" == "${desiredGroupMembers[j]}" ]] && continue 2
  done
  membersToRemove="${membersToRemove} ${existingGroupMembers[i]}"
done

set +x
echo "##vso[task.setvariable variable=membersToAdd;isOutput=true]${membersToAdd}"
echo "##vso[task.setvariable variable=membersToRemove;isOutput=true]${membersToRemove}"

# vim: set ts=2 sts=2 sw=2 et:
