#!/bin/bash

set -ux

logInfo() {
  echo "[add-principal-to-group] $*" >&2
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

  logInfo "Graph token claims: oid=${callerObjectId:-<empty>} appid=${callerAppId:-<empty>} tid=${callerTenantId:-<empty>} aud=${tokenAudience:-<empty>} scp=${tokenScopes:-<empty>} roles=${tokenRoles}"

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

printMembershipRefDebug() {
  local token="$1"
  local groupObjectId="$2"
  local principalObjectId="$3"
  local membershipStatus=

  membershipStatus="$(runWithXtraceHidden curl -w '%{http_code}' -s -o /dev/null -H "Authorization: Bearer ${token}" "https://graph.microsoft.com/v1.0/groups/${groupObjectId}/members/${principalObjectId}/\$ref")"
  if [[ $? -eq 0 ]]; then
    logInfo "Membership ref status for principal '${principalObjectId}' in group '${groupObjectId}': HTTP ${membershipStatus}"
  else
    logInfo "Failed to query membership ref for principal '${principalObjectId}' in group '${groupObjectId}'"
  fi
}

TOKEN="$(runWithXtraceHidden az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

callerObjectId="$(jq -r '.oid // empty' <<<"$(decodeJwtPayload "${TOKEN}")")"
printAuthDebug "${TOKEN}"
printGroupDebug "${TOKEN}" "${GROUP_ID}" "${callerObjectId}"
printMemberDebug "${TOKEN}" "${PRINCIPAL_ID}"

max_attempts=10
attempt=0

while (( attempt < max_attempts )); do
  (( attempt++ ))

  RESULT="$(az ad group member add -g "${GROUP_ID}" --member-id "${PRINCIPAL_ID}" 2>&1)"
  STATUS=$?
  if (( STATUS == 0 )); then
    logInfo "Successfully added principal '${PRINCIPAL_ID}' to group '${GROUP_ID}' on attempt ${attempt}/${max_attempts}"
    exit 0
  fi

  if [[ "${RESULT}" =~ "One or more added object references already exist" ]]; then
    logInfo "Principal '${PRINCIPAL_ID}' is already a member of group '${GROUP_ID}'"
    exit 0
  fi

  if [[ "${RESULT}" =~ "Insufficient privileges" ]]; then
    logInfo "Insufficient privileges when adding principal '${PRINCIPAL_ID}' to group '${GROUP_ID}'. Raw CLI output: ${RESULT}"
    printMembershipRefDebug "${TOKEN}" "${GROUP_ID}" "${PRINCIPAL_ID}"
    exit 1
  fi

  [[ "${RESULT}" =~ "Invalid" ]] && exit 1

  logInfo "Attempt ${attempt}/${max_attempts} failed for group '${GROUP_ID}' principal '${PRINCIPAL_ID}': ${RESULT}"
  sleep 10
done

logInfo "Unable to add principal '${PRINCIPAL_ID}' to group '${GROUP_ID}' after ${max_attempts} attempts"
exit 1

# vim: set ts=2 sts=2 sw=2 et:
