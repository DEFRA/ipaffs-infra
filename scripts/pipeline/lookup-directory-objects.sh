#!/bin/bash

## lookup-directory-objects.sh
##
## Wraps the `look-directory-object.sh` script to find multiple Entra principals. The supplied names should
## all be of the same principal type. Finding different types of principals requires invoking this script
## multiple times (one for each principal type).
##
## Required script arguments:
## -t TYPE    The type of principal to search for. TYPE is one of: `group`, `servicePrincipal`, or `user`.
##
## Optional script arguments:
## -o OUTPUT  The type of output the script should produce. OUTPUT is one of: `oid`, `odataUri`, or `ado`.
##            Defaults to `oid` if not specified.
##
## Required environment variables:
## NAMES - Space-separated set of principal names to locate. For groups or service principals, this
##         should be the display name. For users, this should be the user principal name (UPN).
##
## Standard output:
## When OUTPUT is `oid`, a space-separated set of object IDs is printed to stdout.
## When OUTPUT is `odataUri`, a space-separated set of OData URIs is printed to stdout.
##
## ADO Variable Outputs (only emitted when OUTPUT is `ado`):
## objectId - The object ID of the group/servicePrincipal/user.
## odataUri - The OData URI of the object, for use when creating relationship records with MS Graph.

set -ux

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"
source "${SCRIPTS_DIR}/pipeline/_common.sh"

output=oid
objectType=

while getopts "o:t:" opt; do
  case $opt in
    o)
      output="${OPTARG}"
      ;;
    t)
      objectType="${OPTARG}"
      ;;
  esac
done

if [[ "${objectType}" == "" ]]; then
  echo "Must specify object type" >&2
  exit 1
fi

# Parse names (can be UPNs for users, or displayNames for groups/service principals)
declare -a names
if [[ -n "${NAMES}" ]]; then
  cleanNames="$(echo "${NAMES}" | tr -d '\n')"
  IFS=' ' read -ra names <<<"${cleanNames}"
fi

# Output members
oids=
odataUris=
for i in "${!names[@]}"; do
  name="$(echo "${names[i]}" | awk '{$1=$1};1')"
  [[ "${name}" == "" ]] && continue

  oid="$(OBJECT_NAME="${name}" OBJECT_TYPE="${objectType}" "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh" -o oid)"
  [[ $? -ne 0 ]] && exit 1
  odataUri="$(getODataUri "${oid}" "${objectType}")"
  [[ $? -ne 0 ]] && exit 1

  oids="${oids} ${oid}"
  odataUris="${odataUris} ${odataUri}"
done

case "${output}" in
  oid)
    set +x
    echo "${oids}"
    ;;
  odataUri|odataUris)
    set +x
    echo "${odataUris}"
    ;;
  ado)
    set +x
    echo "##vso[task.setvariable variable=objectIds;isOutput=true]${oids}"
    echo "##vso[task.setvariable variable=odataUris;isOutput=true]${odataUris}"
    ;;
  none)
    ;;
esac

# vim: set ts=2 sts=2 sw=2 et:
