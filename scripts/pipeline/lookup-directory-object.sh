#!/bin/bash

set -ux

output=plain

while getopts "o:" opt; do
  case $opt in
    o)
      output="${OPTARG}"
      ;;
  esac
done

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

parseObjectId() {
  local result="${1}"
  [[ "$(jq -r '.error.code' <<<"${result}")" == "null" ]] || exit 1
  local objectId="$(jq -r '.value[0].id' <<<"${result}")"
  if [[ -n "${objectId}" ]] && [[ "${objectId}" != "null" ]]; then
    echo "${objectId}"
    return 0
  fi
  return 1
}

oid=
searchResult=
case "${OBJECT_TYPE}" in
  group)
    searchResult="$(curl -H "Authorization: Bearer ${TOKEN}" "https://graph.microsoft.com/v1.0/groups?\$filter=displayName+eq+'${OBJECT_NAME}'")"
    [[ $? -ne 0 ]] && exit 1
    ;;
  servicePrincipal)
    searchResult="$(curl -H "Authorization: Bearer ${TOKEN}" "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=displayName+eq+'${OBJECT_NAME}'")"
    [[ $? -ne 0 ]] && exit 1
    ;;
  user)
    searchResult="$(curl -H "Authorization: Bearer ${TOKEN}" "https://graph.microsoft.com/v1.0/users?\$filter=userPrincipalName+eq+'${OBJECT_NAME}'")"
    [[ $? -ne 0 ]] && exit 1
    ;;
  *)
    echo "Invalid OBJECT_TYPE specified: \`${OBJECT_TYPE}\`" >&2
    exit 1
    ;;
esac

oid="$(parseObjectId "${searchResult}")"
[[ $? -ne 0 ]] && exit 1

case "${output}" in
  plain)
    set +x
    echo "${oid}"
    ;;
  ado)
    set +x
    echo "##vso[task.setvariable variable=objectId;isOutput=true]${oid}"
    ;;
  none)
    ;;
esac

# vim: set ts=2 sts=2 sw=2 et:
