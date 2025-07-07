#!/usr/bin/env bash
set -euo pipefail

# option flags
dirOpt="false"

# echo colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# constants
XPATHS=(
  '/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/properties/org.jenkinsci.plugins.workflow.libs.FolderLibraries/libraries/org.jenkinsci.plugins.workflow.libs.LibraryConfiguration/retriever/scm/remote'
  '/flow-definition/definition/scm/userRemoteConfigs/hudson.plugins.git.UserRemoteConfig/url'
  '/org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject/sources/data/jenkins.branch.BranchSource/source/remote'
)

if sed --version 2>&1 1>/dev/null; then
  SED="sed -E -i" # GNU
else
  SED="sed -E -i ''" # BSD
fi

while getopts "d:" opt; do
  case $opt in
    d)
      dirOpt=true
      dirName="$OPTARG"
      ;;
    \?)
      usage
      exit 0
      ;;
  esac
done

function usage() {
  echo "Usage: $0 [-d directory]"
}

function modify_version_start() {
  $SED 's/(<\?xml version=)(["'\''])1\.1/\1\21.0/' "$1"
}

function modify_version_end() {
  $SED 's/(<\?xml version=)(["'\''])1\.0/\1\21.1/' "$1"
}

function update_xml_element() {
  trap 'modify_version_end "$2"' RETURN
  modify_version_start "$2"

  repositoryName=$(xmlstarlet sel -t -v "$1" "$2")
  if [[ -z "${repositoryName:-}" ]]; then return 1; fi

  updatedRepostoryValue=https://github.com/DEFRA/ipaffs-$(basename "$repositoryName")
  # xmlstarlet ed -L -u "$1" -v $updatedRepostoryValue $file

  echo "${updatedRepostoryValue}"
  return 0
}

if [[ "$dirOpt" == "true" ]]; then
  if [[ -d "$dirName" ]]; then
    declare -i counter=0
    declare -i failed=0
    while read -r file; do
      echo -e ":: Processing file: $file"
        counter=$((counter + 1))
        success=false
        for xpath in "${XPATHS[@]}"; do
          if result=$(update_xml_element "$xpath" "$file"); then
            echo -e "$BLUE\n:: Updating element 'remote' to value \`$result\` with xpath \`$xpath\` $NC\n"
            success=true
            break
          fi
        done
        if [[ "$success" == "false" ]]; then
          echo -e "$RED\n:: No elements to update have been found. $NC" >&2
          failed=$((failed + 1))
        fi
    done < <(find "$dirName" -type f -name "config.xml") # don't subshell we want to track counters
    echo -e "Operation completed.\n\nJobs migrated     : $counter\nJobs not migrated : $failed" >&2
  else
    echo -e "$RED\n:: $dirName is not a directory $NC"
    exit 1
  fi
fi
