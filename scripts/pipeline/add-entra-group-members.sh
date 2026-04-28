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
## Note: This script will _not_ gracefully handle adding a group member that already exists. The provided
## set of GROUP_MEMBERS should have no duplicates, and should not include any existing group members.

set -x

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"

logInfo() {
  echo "[add-entra-group-members] $*" >&2
}

runWithXtraceHidden() {
  local hadXtrace=0
  [[ "$-" == *x* ]] && hadXtrace=1
  (( hadXtrace == 1 )) && set +x
  "$@"
  local status=$?
  (( hadXtrace == 1 )) && set -x
  return $status
}

decodeJwtPayload() {
  local token="$1"
  local payload=
  payload="$(echo "${token}" | cut -d. -f2)"
  payload="${payload//-/+}"
  payload="${payload//_/\/}"

  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
    1) payload="${payload}===" ;;
  esac

  echo "${payload}" | base64 -d 2>/dev/null
}

printAuthDebug() {
  local token="$1"
  local accountJson=
  local claimsJson=
  local callerObjectId=
  local callerAppId=
  local callerTenantId=
  local tokenAudience=
  local tokenScopes=
  local tokenRoles=
  local tokenSubject=
  local spSummary=

  accountJson="$(az account show --query '{subscriptionId:id,subscriptionName:name,tenantId:tenantId,userType:user.type,userName:user.name}' -o json 2>/dev/null)"
  if [[ $? -eq 0 ]] && [[ -n "${accountJson}" ]]; then
    logInfo "Azure account context: $(jq -c . <<<"${accountJson}")"
  else
    logInfo "Unable to read Azure account context"
  fi

  claimsJson="$(decodeJwtPayload "${token}")"
  if [[ $? -ne 0 ]] || [[ -z "${claimsJson}" ]]; then
    logInfo "Unable to decode Graph access token claims"
    return
  fi

  callerObjectId="$(jq -r '.oid // empty' <<<"${claimsJson}")"
  callerAppId="$(jq -r '.appid // empty' <<<"${claimsJson}")"
  callerTenantId="$(jq -r '.tid // empty' <<<"${claimsJson}")"
  tokenAudience="$(jq -r '.aud // empty' <<<"${claimsJson}")"
  tokenScopes="$(jq -r '.scp // empty' <<<"${claimsJson}")"
  tokenRoles="$(jq -c '.roles // []' <<<"${claimsJson}")"
  tokenSubject="$(jq -r '.sub // empty' <<<"${claimsJson}")"

  logInfo "Graph token claims: oid=${callerObjectId:-<empty>} appid=${callerAppId:-<empty>} tid=${callerTenantId:-<empty>} aud=${tokenAudience:-<empty>} sub=${tokenSubject:-<empty>} scp=${tokenScopes:-<empty>} roles=${tokenRoles}"

  if [[ -n "${callerAppId}" ]]; then
    spSummary="$(az ad sp show --id "${callerAppId}" --query '{id:id,appId:appId,displayName:displayName,servicePrincipalType:servicePrincipalType}' -o json 2>/dev/null)"
    if [[ $? -eq 0 ]] && [[ -n "${spSummary}" ]]; then
      logInfo "Resolved caller service principal: $(jq -c . <<<"${spSummary}")"
    else
      logInfo "Unable to resolve caller service principal by appId '${callerAppId}'"
    fi
  fi
}

printGroupDebug() {
  local token="$1"
  local groupObjectId="$2"
  local callerObjectId="$3"
  local groupSummary=
  local ownerSample=
  local ownerCount=
  local callerIsOwner=
  local ownerRefStatus=

  groupSummary="$(runWithXtraceHidden curl -s -H "Authorization: Bearer ${token}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}?\$select=id,displayName,mailEnabled,securityEnabled,isAssignableToRole,groupTypes")"
  if [[ $? -eq 0 ]] && [[ -n "${groupSummary}" ]]; then
    if [[ "$(jq -r '.error.code // empty' <<<"${groupSummary}")" != "" ]]; then
      logInfo "Failed to read target group metadata: $(jq -c '.error' <<<"${groupSummary}")"
    else
      logInfo "Target group metadata: $(jq -c '{id,displayName,mailEnabled,securityEnabled,isAssignableToRole,groupTypes}' <<<"${groupSummary}")"
    fi
  else
    logInfo "Failed to query target group metadata for '${groupObjectId}'"
  fi

  ownerSample="$(runWithXtraceHidden curl -s -H "Authorization: Bearer ${token}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}/owners?\$select=id,displayName")"
  if [[ $? -eq 0 ]] && [[ -n "${ownerSample}" ]]; then
    if [[ "$(jq -r '.error.code // empty' <<<"${ownerSample}")" != "" ]]; then
      logInfo "Failed to list group owners: $(jq -c '.error' <<<"${ownerSample}")"
    else
      ownerCount="$(jq -r '.value | length' <<<"${ownerSample}")"
      logInfo "Group owner count: ${ownerCount}"
      logInfo "Group owner sample (up to 5): $(jq -c '.value[:5] | map({id,displayName})' <<<"${ownerSample}")"
      if [[ -n "${callerObjectId}" ]]; then
        callerIsOwner="$(jq -r --arg oid "${callerObjectId}" '[.value[] | select(.id == $oid)] | length' <<<"${ownerSample}")"
        if [[ "${callerIsOwner}" != "0" ]]; then
          logInfo "Caller object '${callerObjectId}' is listed as an owner of group '${groupObjectId}'"
        else
          logInfo "Caller object '${callerObjectId}' is NOT listed as an owner of group '${groupObjectId}'"
        fi
      fi
    fi
  else
    logInfo "Failed to query group owners for '${groupObjectId}'"
  fi

  if [[ -n "${callerObjectId}" ]]; then
    ownerRefStatus="$(runWithXtraceHidden curl -w '%{http_code}' -s -o /dev/null -H "Authorization: Bearer ${token}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}/owners/${callerObjectId}/\$ref")"
    if [[ $? -eq 0 ]]; then
      case "${ownerRefStatus}" in
        200)
          logInfo "Direct owner ref check: caller '${callerObjectId}' IS an owner of group '${groupObjectId}' (HTTP 200)"
          ;;
        404)
          logInfo "Direct owner ref check: caller '${callerObjectId}' is NOT an owner of group '${groupObjectId}' (HTTP 404)"
          ;;
        403)
          logInfo "Direct owner ref check for caller '${callerObjectId}' on group '${groupObjectId}' was denied (HTTP 403)"
          ;;
        *)
          logInfo "Direct owner ref check for caller '${callerObjectId}' on group '${groupObjectId}' returned HTTP ${ownerRefStatus}"
          ;;
      esac
    else
      logInfo "Direct owner ref check failed for caller '${callerObjectId}' on group '${groupObjectId}'"
    fi
  fi
}

printMemberDebug() {
  local token="$1"
  local oid="$2"
  local memberObject=

  memberObject="$(runWithXtraceHidden curl -s -H "Authorization: Bearer ${token}" "https://graph.microsoft.com/v1.0/directoryObjects/${oid}")"
  if [[ $? -eq 0 ]] && [[ -n "${memberObject}" ]]; then
    if [[ "$(jq -r '.error.code // empty' <<<"${memberObject}")" != "" ]]; then
      logInfo "Member '${oid}' lookup failed: $(jq -c '.error' <<<"${memberObject}")"
    else
      logInfo "Member '${oid}' resolved: $(jq -c '{id,displayName,userPrincipalName,appId,"@odata.type"}' <<<"${memberObject}")"
    fi
  else
    logInfo "Member '${oid}' lookup call failed"
  fi
}

TOKEN="$(runWithXtraceHidden az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

printAuthDebug "${TOKEN}"

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

callerObjectId="$(jq -r '.oid // empty' <<<"$(decodeJwtPayload "${TOKEN}")")"
printGroupDebug "${TOKEN}" "${groupObjectId}" "${callerObjectId}"

# Parse member URIs
declare -a memberIds
if [[ -n "${GROUP_MEMBERS}" ]]; then
  cleanMembers="$(echo "${GROUP_MEMBERS}" | tr -d '\n')"
  IFS=' ' read -ra memberIds <<<"${cleanMembers}"
fi

if [[ ${#memberIds[@]} -gt 0 ]]; then
  logInfo "Preparing to add ${#memberIds[@]} member(s) to group '${groupObjectId}'"
fi

# Compile members
membersJson=
for i in "${!memberIds[@]}"; do
  oid="$(echo "${memberIds[i]}" | awk '{$1=$1};1')"
  printMemberDebug "${TOKEN}" "${oid}"
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
groupResult="$(runWithXtraceHidden curl -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json; charset=utf-8" -d "${groupJson}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}")"
[[ $? -ne 0 ]] && exit 1
errorCode="$(jq -r '.error.code' <<<"${groupResult}")"
if [[ "${errorCode}" != "null" ]] && [[ "${errorCode}" != "" ]]; then
  logInfo "Group update failed: $(jq -c '.error' <<<"${groupResult}")"
  exit 1
fi

logInfo "Successfully added requested members to group '${groupObjectId}'"

exit 0

# vim: set ts=2 sts=2 sw=2 et:
