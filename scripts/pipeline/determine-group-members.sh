#!/bin/bash

## determine-group-members.sh
##
## Given a declarative set of desired group members, queries a group to determine which new members need
## to be added, and which existing group members need to be removed, to achieve the desired member set.
##
## Required environment variables:
## GROUP_NAME - The display name of a group to locate and add members
## GROUP_ID   - The object ID of a group to add members
## OBJECT_IDS - Space-delimited declarative set of member object IDs the group should have.
##
## One of GROUP_ID or GROUP_NAME should be provided. Specifying GROUP_ID avoids searching for the group,
## which is useful when the script does not have permissions to read all group details.
##
## ADO Variable Outputs:
## membersToAdd    - Space-delimited set of object IDs that will need adding as group members.
## membersToRemove - Space-delimited set of object IDs that will need removing as group members.

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

membersResult="$(curl -H "Authorization: Bearer ${TOKEN}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}/members?\$select=id,userPrincipalName")"
[[ $? -ne 0 ]] && exit 1
errorCode="$(jq -r '.error.code' <<<"${membersResult}")"
[[ "${errorCode}" == "null" ]] || [[ "${errorCode}" == "" ]] || exit 1

# Parse existing group member object IDs
mapfile -t existingGroupMembers < <(echo "${membersResult}" | jq -r '.value[].id')

# Parse desired member object IDs
declare -a desiredGroupMembers
if [[ -n "${OBJECT_IDS}" ]]; then
  cleanMembers="$(echo "${OBJECT_IDS}" | tr -d '\n')"
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
