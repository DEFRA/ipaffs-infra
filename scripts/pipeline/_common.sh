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

getODataUri() {
  local oid="${1}"
  local objectType="${2:-directoryObject}"

  case "${objectType}" in
    directoryObject)
      echo "https://graph.microsoft.com/v1.0/directoryObjects/${oid}"
      ;;
    group)
      echo "https://graph.microsoft.com/v1.0/groups/${oid}"
      ;;
    servicePrincipal)
      echo "https://graph.microsoft.com/v1.0/servicePrincipals/${oid}"
      ;;
    user)
      echo "https://graph.microsoft.com/v1.0/users/${oid}"
      ;;
    *)
      echo "Invalid object type specified: \`${OBJECT_TYPE}\`" >&2
      exit 1
      ;;
  esac
}
