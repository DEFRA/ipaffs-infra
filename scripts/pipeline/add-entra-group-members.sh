#!/bin/bash

## add-entra-group-members.sh
##
## Adds one or more members to an Entra group.
##
## Required environment variables:
## GROUP_NAME    - The display name of a group to locate and add members
## GROUP_ID      - The object ID of a group to add members
## GROUP_MEMBERS - Space-delimited set of member object IDs to add to the group
##
## One of GROUP_ID or GROUP_NAME should be provided. Specifying GROUP_ID avoids searching for the group,
## which is useful when the script does not have permissions to read all group details.
##
## Add requests are chunked at 20 members because Microsoft Graph only supports adding up to 20
## members in a single PATCH request.
##
## Optional environment variables:
## CHECK_EXISTING_MEMBERS - When true, skips members already present in the group before adding.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"

logInfo() {
  echo "[add-entra-group-members] $*" >&2
}

: "${GROUP_MEMBERS:=}"
CHECK_EXISTING_MEMBERS="${CHECK_EXISTING_MEMBERS:-false}"

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"

# Check for existing group
groupObjectId=
if [[ -n "${GROUP_ID:-}" ]]; then
  groupObjectId="${GROUP_ID}"
else
  : "${GROUP_NAME:?GROUP_ID or GROUP_NAME is required}"
  groupObjectId="$(OBJECT_NAME="${GROUP_NAME}" OBJECT_TYPE=group "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh" -o oid)"
fi

# Parse unique member IDs.
declare -a memberIds
if [[ -n "${GROUP_MEMBERS:-}" ]]; then
  cleanMembers="$(echo "${GROUP_MEMBERS}" | tr -d '\n')"
  IFS=' ' read -ra memberIds <<<"${cleanMembers}"
fi

declare -A seenMemberIds=()
declare -a uniqueMemberIds=()
for memberId in "${memberIds[@]}"; do
  memberId="$(echo "${memberId}" | awk '{$1=$1};1')"
  [[ -z "${memberId}" ]] && continue
  if [[ -z "${seenMemberIds[${memberId}]+x}" ]]; then
    seenMemberIds["${memberId}"]=1
    uniqueMemberIds+=("${memberId}")
  fi
done

if [[ ${#uniqueMemberIds[@]} -eq 0 ]]; then
  echo "No members to be added" >&2
  exit 0
fi

declare -a missingMemberIds=()
chunk_size=20

if [[ "${CHECK_EXISTING_MEMBERS}" == "true" ]]; then
  for (( start=0; start<${#uniqueMemberIds[@]}; start+=chunk_size )); do
    chunk=("${uniqueMemberIds[@]:start:chunk_size}")
    chunkMembers="${chunk[*]}"
    batchJson="$(jq -n --arg groupId "${groupObjectId}" --arg memberIds "${chunkMembers}" '
      ($memberIds | split(" ") | map(select(length > 0))) as $ids
      | {
          requests: [
            $ids
            | to_entries[]
            | {
                id: (.key | tostring),
                method: "GET",
                url: ("/groups/" + $groupId + "/members/" + .value + "/$ref")
              }
          ]
        }
    ')"

    batchResult="$(curl -sS -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "${batchJson}" "https://graph.microsoft.com/v1.0/\$batch")"
    errorCode="$(jq -r '.error.code // empty' <<<"${batchResult}")"
    if [[ -n "${errorCode}" ]]; then
      logInfo "Membership lookup batch failed for group '${groupObjectId}': $(jq -c '.error' <<<"${batchResult}")"
      exit 1
    fi

    while IFS= read -r missingMemberId; do
      [[ -n "${missingMemberId}" ]] && missingMemberIds+=("${missingMemberId}")
    done < <(jq -r --arg memberIds "${chunkMembers}" '
      ($memberIds | split(" ") | map(select(length > 0))) as $ids
      | .responses[]
      | select(.status == 404)
      | $ids[(.id | tonumber)]
    ' <<<"${batchResult}")

    unexpectedFailures="$(jq -c '[.responses[] | select(.status != 200 and .status != 404)]' <<<"${batchResult}")"
    if [[ "${unexpectedFailures}" != "[]" ]]; then
      logInfo "Unexpected membership lookup response for group '${groupObjectId}': ${unexpectedFailures}"
      exit 1
    fi
  done

  if [[ ${#missingMemberIds[@]} -eq 0 ]]; then
    logInfo "All requested members are already present in group '${groupObjectId}'"
    exit 0
  fi
else
  missingMemberIds=("${uniqueMemberIds[@]}")
fi

for (( start=0; start<${#missingMemberIds[@]}; start+=chunk_size )); do
  chunk=("${missingMemberIds[@]:start:chunk_size}")
  chunkMembers="${chunk[*]}"
  groupJson="$(jq -n --arg memberIds "${chunkMembers}" '
    {
      "members@odata.bind": [
        ($memberIds | split(" ") | map(select(length > 0))[] | "https://graph.microsoft.com/v1.0/directoryObjects/" + .)
      ]
    }
  ')"

  responseFile="$(mktemp)"
  statusCode="$(curl -sS -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "${groupJson}" -o "${responseFile}" -w "%{http_code}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}")"
  groupResult="$(cat "${responseFile}")"
  rm -f "${responseFile}"

  if [[ "${statusCode}" != "204" ]]; then
    if [[ "${groupResult}" =~ "One or more added object references already exist" || "${statusCode}" == "403" || "${groupResult}" =~ "Authorization_RequestDenied" ]]; then
      logInfo "Bulk group update for group '${groupObjectId}' could not complete; falling back to idempotent per-member adds for this chunk"
      for memberId in "${chunk[@]}"; do
        GROUP_ID="${groupObjectId}" \
        PRINCIPAL_ID="${memberId}" \
        "${SCRIPTS_DIR}/pipeline/add-principal-to-group.sh"
      done
      continue
    fi

    if [[ -n "${groupResult}" ]] && jq -e '.error' >/dev/null 2>&1 <<<"${groupResult}"; then
      logInfo "Group update failed with HTTP ${statusCode}: $(jq -c '.error' <<<"${groupResult}")"
    else
      logInfo "Group update failed with HTTP ${statusCode}: ${groupResult}"
    fi
    exit 1
  fi
done

logInfo "Successfully added ${#missingMemberIds[@]} requested members to group '${groupObjectId}'"

exit 0

# vim: set ts=2 sts=2 sw=2 et:
