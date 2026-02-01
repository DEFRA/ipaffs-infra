#!/bin/bash

## lookup-directory-object.sh
##
## Searches for an Entra group, service principal or user by name and returns the object ID, along with
## the OData URI for use in creating relationship records (e.g. members, owners, managers etc).
##
## Required environment variables:
## OBJECT_NAME - The name of the object to find. For groups or service principals, this should be the
##               display name. For users, this should be the user principal name (UPN).
## OBJECT_TYPE - The type of object to find, one of: `group`, `servicePrincipal`, or `user`.
##
## ADO Variable Outputs:
## objectId - The object ID of the group/servicePrincipal/user.
## odataUri - The OData URI of the object, for use when creating relationship records with MS Graph.

set -ux

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"
source "${SCRIPTS_DIR}/pipeline/_common.sh"

output=oid

while getopts "o:" opt; do
  case $opt in
    o)
      output="${OPTARG}"
      ;;
  esac
done

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

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
odataUri="$(getODataUri "${oid}" "${OBJECT_TYPE}")"
[[ $? -ne 0 ]] && exit 1

case "${output}" in
  oid)
    set +x
    echo "${oid}"
    ;;
  odataUri)
    set +x
    echo "${odataUri}"
    ;;
  ado)
    set +x
    echo "##vso[task.setvariable variable=objectId;isOutput=true]${oid}"
    echo "##vso[task.setvariable variable=odataUri;isOutput=true]${odataUri}"
    ;;
  none)
    ;;
esac

# vim: set ts=2 sts=2 sw=2 et:
