#!/usr/bin/env bash
set -euo pipefail
#set -x

# Constants
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly PATH_EXCLUSION_MASK='*migrator*';

readonly DOCUMENT1_XPATH1='/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/properties/org.jenkinsci.plugins.workflow.libs.FolderLibraries/libraries/org.jenkinsci.plugins.workflow.libs.LibraryConfiguration/retriever/scm/remote'
readonly DOCUMENT1_XPATH2='/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/properties/org.jenkinsci.plugins.workflow.libs.FolderLibraries/libraries/org.jenkinsci.plugins.workflow.libs.LibraryConfiguration/retriever/scm/credentialsId'
readonly DOCUMENT1_XPATH3='/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/sources/data/jenkins.branch.BranchSource/source/remote'
readonly DOCUMENT1_XPATH4='/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/sources/data/jenkins.branch.BranchSource/source/credentialsId'
readonly DOCUMENT1_XPATH5='/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/properties/org.jenkinsci.plugins.workflow.libs.FolderLibraries/libraries/org.jenkinsci.plugins.workflow.libs.LibraryConfiguration/defaultVersion'
readonly DOCUMENT1_XPATH6='/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/sources/data/jenkins.branch.BranchSource/source/traits/jenkins.scm.impl.trait.RegexSCMHeadFilterTrait/regex'

readonly DEFRA_GITHUB_PATH_PREFIX='https://github.com/DEFRA/ipaffs-'
readonly CREDENTIALS_ID='github-token'
readonly DEFAULT_VERSION='main'

readonly XPATHS=(
  "$DOCUMENT1_XPATH1 $DOCUMENT1_XPATH2 $DOCUMENT1_XPATH3 $DOCUMENT1_XPATH4 $DOCUMENT1_XPATH5 $DOCUMENT1_XPATH6"
)

dirname=
filename=

# Script pre-requisites
if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  echo -e "${RED}Error: this script requires Bash 4.0 or newer${NC}"
fi
if ! command -v xmlstarlet >/dev/null 2>&1; then
  echo -e "${RED}Error: \`xmlstarlet\` not available in PATH. Please install XMLStarlet.${NC}" >&2
  exit 1
fi

function usage() {
  cat >&2 <<EOF
Usage: $0 (-d /path/to/directory | -f /path/to/file) [-c /path/to/source/file]

-d  Specify path to a directory in which to update job configurations
-f  Specify single job configuration file to create/update
EOF
}

SED() {
  if sed --version 2>/dev/null 1>/dev/null; then
    # GNU
    sed -E -i "${1}" "${2}"
  else
    # BSD
    sed -E -i '' "${1}" "${2}"
  fi
}

while getopts "d:f:" opt; do
  case $opt in
    d)
      dirname="${OPTARG}"
      ;;
    f)
      filename="${OPTARG}"
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
fi
if [[ -n "${dirname}" && -n "${filename}" ]]; then
  echo -e "${RED}:: Can't specify both -d and -f${NC}" >&2;
  exit 1
fi
if [[ -n "${dirname}" && ! -d "${dirname}" ]]; then
  echo -e "${RED}:: \`${dirname}\` is not a directory${NC}" >&2;
  exit 1
fi
if [[ -n "${filename}" && ! -f "${filename}" ]]; then
  echo -e "${RED}:: \`${dirname}\` is not a filename${NC}" >&2;
  exit 1
fi

function modify_version_start() {
  SED 's/(<\?xml version=)(["'\''])1\.1/\1\21.0/' "${1}"
}

function modify_version_end() {
  SED 's/(<\?xml version=)(["'\''])1\.0/\1\21.1/' "${1}"
}

function update_element() {
  local docment_xpaths="${1:?"Value expected for argument: docment_xpaths"}"
  local filename="${2?"Value expected for argument: filename"}"

  trap 'modify_version_end "${filename}"' RETURN
  modify_version_start "${filename}"

  elementValue=$(xmlstarlet sel -t -v "$1" "$2")
  if [[ -z "${elementValue:-}" ]]; then return 1; fi

  case "${docment_xpaths##*/}" in
    remote)
      updatedElementValue="${DEFRA_GITHUB_PATH_PREFIX}${elementValue##*/}"
      ;;
    credentialsId)
      updatedElementValue="${CREDENTIALS_ID}"
      ;;
    defaultVersion)
      updatedElementValue="${DEFAULT_VERSION}"
      ;;
    regex)
      updatedElementValue="${elementValue//master/main}"
      ;;
    *)
      echo -e "${RED}:: Unmatched element ${elementValue}${NC}" >&2
      exit 1
      ;;
  esac
  # xmlstarlet ed -L -u "$1" -v $updatedElementValue $file
  echo "${updatedElementValue}"
  return 0
}

if [[ -n "${filename}" ]]; then
  cp "${filename}" "${filename}.bak"
  echo -e ":: Created backup: ${filename}.bak"
  echo -e ":: Processing file ${filename}"
  success=false
  for docment_xpaths in "${XPATHS[@]}"; do
    for xpath in ${docment_xpaths}; do
       if result=$(update_element "${xpath}" "${filename}"); then
        echo -e "${GREEN}:: Updated elementValue '${xpath##*/}' to value \`${result}\`${NC}"
        success=true
      fi
    done
  done
  if [[ "${success}" == "false" ]]; then
      echo -e "${BLUE}:: No elements to update have been found${NC}" >&2
  fi
  echo -e "Operation completed.\n"
fi

if [[ -n "${dirname}" ]]; then
  tarball="${dirname}-$(date +%Y%m%d).tar.gz"
  tar czf "${tarball}" "${dirname}"
  echo -e ":: Created backup: ${tarball}"

  declare -i counter=0
  declare -i skipped=0
  while read -r file; do
    echo -e ":: Processing file ${file}"
      counter=$((counter + 1))
      success=false
      for docment_xpaths in "${XPATHS[@]}"; do
        for xpath in ${docment_xpaths}; do
           if result=$(update_element "${xpath}" "${file}"); then
            echo -e "${GREEN}:: Updated element '${xpath##*/}' to value \`${result}\`${NC}"
            success=true
          fi
        done
      done
      if [[ "${success}" == "false" ]]; then
        echo -e "${BLUE}:: No elements to update have been found${NC}" >&2
        skipped=$((skipped + 1))
      fi
  done < <(find "${dirname}" -type f -name "config.xml" ! -path "${PATH_EXCLUSION_MASK}") # don't subshell
  echo -e "Operation completed.\n\nJobs Migrated : ${counter}\nJobs Skipped  : ${BLUE}${skipped}${NC}"
fi
