#!/bin/bash

## wait-for-group-memberships.sh
##
## Waits until all requested principal IDs are visible as members of one Entra group.
## Membership checks are chunked through Microsoft Graph JSON batching at 20 requests per batch.
##
## Required environment variables:
## GROUP_ID       - The object ID of the group to check
## PRINCIPAL_IDS  - Space-delimited set of principal object IDs expected in the group

set -euo pipefail

: "${GROUP_ID:?GROUP_ID is required}"
: "${PRINCIPAL_IDS:?PRINCIPAL_IDS is required}"

logInfo() {
  echo "[wait-for-group-memberships] $*" >&2
}

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"

cleanPrincipals="$(echo "${PRINCIPAL_IDS}" | tr -d '\n')"
IFS=' ' read -ra principalIds <<<"${cleanPrincipals}"

declare -A seenPrincipalIds=()
declare -a expectedPrincipalIds=()
for principalId in "${principalIds[@]}"; do
  principalId="$(echo "${principalId}" | awk '{$1=$1};1')"
  [[ -z "${principalId}" ]] && continue
  if [[ -z "${seenPrincipalIds[${principalId}]+x}" ]]; then
    seenPrincipalIds["${principalId}"]=1
    expectedPrincipalIds+=("${principalId}")
  fi
done

if [[ ${#expectedPrincipalIds[@]} -eq 0 ]]; then
  logInfo "No principals supplied for group '${GROUP_ID}'"
  exit 0
fi

max_attempts=30
attempt=0
wait=2
chunk_size=20

while (( attempt < max_attempts )); do
  (( ++attempt ))
  declare -a missingPrincipalIds=()

  for (( start=0; start<${#expectedPrincipalIds[@]}; start+=chunk_size )); do
    chunk=("${expectedPrincipalIds[@]:start:chunk_size}")
    chunkPrincipals="${chunk[*]}"
    batchJson="$(jq -n --arg groupId "${GROUP_ID}" --arg principalIds "${chunkPrincipals}" '
      ($principalIds | split(" ") | map(select(length > 0))) as $ids
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
      logInfo "Membership lookup batch failed for group '${GROUP_ID}': $(jq -c '.error' <<<"${batchResult}")"
      exit 1
    fi

    while IFS= read -r missingPrincipalId; do
      [[ -n "${missingPrincipalId}" ]] && missingPrincipalIds+=("${missingPrincipalId}")
    done < <(jq -r --arg principalIds "${chunkPrincipals}" '
      ($principalIds | split(" ") | map(select(length > 0))) as $ids
      | .responses[]
      | select(.status == 404)
      | $ids[(.id | tonumber)]
    ' <<<"${batchResult}")

    retryableFailures="$(jq -c '[.responses[] | select(.status == 429 or (.status >= 500))]' <<<"${batchResult}")"
    if [[ "${retryableFailures}" != "[]" ]]; then
      missingPrincipalIds+=("${chunk[@]}")
    fi

    unexpectedFailures="$(jq -c '[.responses[] | select(.status != 200 and .status != 404 and .status != 429 and (.status < 500))]' <<<"${batchResult}")"
    if [[ "${unexpectedFailures}" != "[]" ]]; then
      logInfo "Unexpected membership lookup response for group '${GROUP_ID}': ${unexpectedFailures}"
      exit 1
    fi
  done

  if [[ ${#missingPrincipalIds[@]} -eq 0 ]]; then
    logInfo "All ${#expectedPrincipalIds[@]} expected members are visible in group '${GROUP_ID}'"
    exit 0
  fi

  logInfo "Attempt ${attempt}/${max_attempts}: waiting for ${#missingPrincipalIds[@]} members in group '${GROUP_ID}'"
  sleep "${wait}"
  (( wait*=2 ))
  (( wait > 60 )) && wait=60
done

logInfo "Timed out waiting for group '${GROUP_ID}' memberships"
exit 1

