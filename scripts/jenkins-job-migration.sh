#!/usr/bin/env bash
set -euo pipefail
#set -x

# echo colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  echo -e "${RED}Error: this script requires Bash 4.0 or newer${NC}"
fi

remote_xpaths=(
  '/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/properties/org.jenkinsci.plugins.workflow.libs.FolderLibraries/libraries/org.jenkinsci.plugins.workflow.libs.LibraryConfiguration/retriever/scm/remote'
  '/flow-definition/definition/scm/userRemoteConfigs/hudson.plugins.git.UserRemoteConfig/url'
  '/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/sources/data/jenkins.branch.BranchSource/source/remote'
)

SED() {
  if sed --version 2>/dev/null 1>/dev/null; then
    # GNU
    sed -E -i "${1}" "${2}"
  else
    # BSD
    sed -E -i '' "${1}" "${2}"
  fi
}

function usage() {
  echo "Usage: $0 ( -d /path/to/directory | -f /path/to/file )" >&2
  echo >&2
}

dirname=
filename=
revert=

while getopts "d:f:rh" opt; do
  case $opt in
    d)
      dirname="$OPTARG"
      ;;
    f)
      filename="$OPTARG"
      ;;
    r)
      revert=1
      ;;
    \?)
      usage
      exit 0
      ;;
  esac
done

if [[ -z "${dirname}" && -z "${filename}" ]]; then
  usage
  exit 1
elif [[ -n "${dirname}" && ! -d "${dirname}" ]]; then
  echo -e "\n${RED}:: \`${dirname}\` is not a directory ${NC}"
  exit 1
elif [[ -n "${filename}" && ! -r "${filename}" ]]; then
  echo -e "\n${RED}:: \`${filename}\` does not exist ${NC}"
  exit 1
fi

if ! command -v xmlstarlet >/dev/null 2>&1; then
  echo -e "${RED}Error: \`xmlstarlet\` not available in PATH. Please install XMLStarlet.${NC}" >&2
  exit 1
fi

function modify_version_start() {
  SED 's/(<\?xml version=)(["'\''])1\.1/\1\21.0/' "${1}"
}

function modify_version_end() {
  SED 's/(<\?xml version=)(["'\''])1\.0/\1\21.1/' "${1}"
}

function update_git_remote_for_github() {
  local filename="${1}"

  trap "modify_version_end '${filename}'" RETURN
  modify_version_start "${filename}"

  for xpath in "${remote_xpaths[@]}"; do
    currentRemote=$(xmlstarlet sel -t -v "${xpath}" "${filename}")
    [[ -z "${currentRemote:-}" ]] && continue
    updatedRemote="https://github.com/DEFRA/ipaffs-${currentRemote##*/}"
    xmlstarlet ed -L -u "${xpath}" -v "${updatedRemote}" "${filename}"
    echo "${updatedRemote}"
    return 0
  done

  return 1
}

function revert_git_remote_for_gitlab() {
  local filename="${1}"

  trap "modify_version_end '${filename}'" RETURN
  modify_version_start "${filename}"

  for xpath in "${remote_xpaths[@]}"; do
    currentRemote=$(xmlstarlet sel -t -v "${xpath}" "${filename}")
    [[ -z "${currentRemote:-}" ]] && continue
    updatedRemote="${currentRemote##https://github.com/DEFRA/ipaffs-}"
    updatedRemote="https://giteux.azure.defra.cloud/imports/${updatedRemote}"
    xmlstarlet ed -L -u "${xpath}" -v "${updatedRemote}" "${filename}"
    echo "${updatedRemote}"
    return 0
  done

  return 1
}

migrate() {
  local filename="${1}"
  echo -e "\n${BLUE}:: Updating git remote to use GitHub for \`${filename}\` ${NC}\n"
  if ! update_git_remote_for_github "${filename}"; then
    echo -e "\n${RED}:: No elements to update have been found. ${NC}" >&2
    return 1
  fi
  return 0
}

revert() {
  local filename="${1}"
  echo -e "\n${BLUE}:: Reverting git remote to use GitLab for \`${filename}\` ${NC}\n"
  if ! revert_git_remote_for_gitlab "${filename}"; then
    echo -e "\n${RED}:: No elements to update have been found. ${NC}" >&2
    return 1
  fi
  return 0
}

if [[ -n "${filename}" ]]; then
  if [[ -z "${revert}" ]]; then
    migrate "${filename}"
  else
    revert "${filename}"
  fi
elif [[ -n "${dirname}" ]]; then
  declare -i counter=0
  declare -i failed=0
  while read -r filename; do
    echo -e ":: Processing file: ${filename}"
    counter=$((counter + 1))
    if [[ -z "${revert}" ]]; then
      migrate "${filename}"
    else
      revert "${filename}"
    fi
  done < <(find "${dirname}" -type f -name "config.xml") # don't subshell we want to track counters
  echo -e "Operation completed.\n\nJobs migrated     : $counter\nJobs not migrated : $failed" >&2
fi
