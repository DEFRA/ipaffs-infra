#!/bin/bash

readonly RED='\033[0;31m'
readonly RRED='\033[0;91m'
readonly GREEN='\033[0;32m'
readonly GGREEN='\033[0;92m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

NOT_TO_MIGRATE_GITLAB=(
  "ansible" ## Not to migrate
  "ansible-jenkins" ## Not to migrate
  "terraform" ## Not to migrate
  "ArchiveNotificationFunction" ## Not to migrate
  "docker-local" ## TODO Broken
  "economicoperator-microservice" ## TODO Broken
  "fieldconfig-microservice" ## TODO Broken
  "ipaffs-files" ## TODO Broken
  "referencedata-microservice" ## TODO Broken
  "scrapy-traces" ## TODO Broken
  "imports-notification-schema" ## TODO Public
  "notify-microservice" ## TODO Public
  "soaprequest-microservice" ## TODO Public
  "spring-boot-common" ## TODO Public
  "spring-boot-common-security" ## TODO Public
  "spring-boot-parent" ## TODO Public
)

SPECIAL_CASES=(
  "ArchiveNotificationFunction,ipaffs-archive-notification-function"
  "import-notification-schema,ipaffs-x-import-notification-schema"
)

if [[ -z "${GIT_SSH_COMMAND}" ]]; then
  export GIT_SSH_COMMAND="ssh -o LogLevel=error"
fi

function usage() {
  cat >&2 <<EOF
Usage: $0 [-b] [-r]

-b  Back up local repositories before making changes
-r  Revert the remote configurations to point back to GitLab
EOF
}

repo_name_from_remote() {
  echo "${1}" | sed 's:.*/::' | sed 's/\.[^.]*$//'
}

github_remote_from_gitlab_remote() {
  REMOTE="${1}"
  REPO_NAME=$(repo_name_from_remote "${REMOTE}")
  APPEND=$(echo "${REMOTE#*${REPO_NAME}}")
  PREPEND=$(echo "${REMOTE%%giteux*}")
  echo "${PREPEND}"github.com:DEFRA/$(github_name_from_gitlab_name "${REPO_NAME}")"${APPEND}"
}

gitlab_remote_from_github_remote() {
  REMOTE="${1}"
  REPO_NAME=$(repo_name_from_remote "${REMOTE}")
  APPEND=$(echo "${REMOTE#*${REPO_NAME}}")
  PREPEND=$(echo "${REMOTE%%github*}")
  echo "${PREPEND}"giteux.azure.defra.cloud:imports/$(gitlab_name_from_github_name "${REPO_NAME}")"${APPEND}"
}

github_name_from_gitlab_name() {
  NAME="${1}"
  for SPECIAL_CASE in "${SPECIAL_CASES[@]}"
  do
    CASE=(${SPECIAL_CASE//,/ })
    if [[ "${NAME}" == "${CASE[0]}" ]]; then
      echo "${CASE[1]}"
      return
    fi
  done
  echo ipaffs-"${NAME}"
}

gitlab_name_from_github_name() {
  NAME="${1}"
  for SPECIAL_CASE in "${SPECIAL_CASES[@]}"
    do
      CASE=(${SPECIAL_CASE//,/ })
      if [[ "${NAME}" == "${CASE[1]}" ]]; then
        echo "${CASE[0]}"
        return
      fi
  done
  echo "${NAME#*ipaffs-*}"
}

point_to_remote() {
  REMOTE="${1}"
  echo -e "Setting remote \`origin\` to: ${REMOTE}"
  git remote set-url origin "${REMOTE}"
  git fetch --quiet
  git remote prune origin > /dev/null 2>&1
  echo The new remote is now: "${REMOTE}"
}

## -------------------
## Start of the script
## -------------------

## ---------------
## Check for flags
## ---------------
REVERSE=
BACKUP=
while getopts "brh" opt; do
  case "${opt}" in
    b)
      BACKUP=true
      ;;
    r)
      REVERSE=true
      ;;
    h)
      usage
      exit 1
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo >&2
      usage
      exit 1
      ;;
  esac
done

## -------------
## Warn the user
## -------------

echo -e "${RRED}
                                @@@@@@@  @@@ @@@@@@@ @@@       @@@@@@  @@@@@@@
                               !@@       @@!   @@!   @@!      @@!  @@@ @@!  @@@
                               !@! @!@!@ !!@   @!!   @!!      @!@!@!@! @!@!@!@
                               :!!   !!: !!:   !!:   !!:      !!:  !!! !!:  !!!
                                :: :: :  :      :    : ::.: :  :   : : :: : ::${NC}"
echo -e "${YELLOW}

                                               .%%%%%%...%%%%..
                                               ...%%....%%..%%.
                                               ...%%....%%..%%.
                                               ...%%....%%..%%.
                                               ...%%.....%%%%..${NC}"
echo -e "${GGREEN}
                                                                                             bbbbbbbb
          GGGGGGGGGGGGG  iiii          tttt          HHHHHHHHH     HHHHHHHHH                 b::::::b
       GGG::::::::::::G i::::i      ttt:::t          H:::::::H     H:::::::H                 b::::::b
     GG:::::::::::::::G  iiii       t:::::t          H:::::::H     H:::::::H                 b::::::b
    G:::::GGGGGGGG::::G             t:::::t          HH::::::H     H::::::HH                  b:::::b
   G:::::G       GGGGGGiiiiiiittttttt:::::ttttttt      H:::::H     H:::::H  uuuuuu    uuuuuu  b:::::bbbbbbbbb
  G:::::G              i:::::it:::::::::::::::::t      H:::::H     H:::::H  u::::u    u::::u  b::::::::::::::bb
  G:::::G               i::::it:::::::::::::::::t      H::::::HHHHH::::::H  u::::u    u::::u  b::::::::::::::::b
  G:::::G    GGGGGGGGGG i::::itttttt:::::::tttttt      H:::::::::::::::::H  u::::u    u::::u  b:::::bbbbb:::::::b
  G:::::G    G::::::::G i::::i      t:::::t            H:::::::::::::::::H  u::::u    u::::u  b:::::b    b::::::b
  G:::::G    GGGGG::::G i::::i      t:::::t            H::::::HHHHH::::::H  u::::u    u::::u  b:::::b     b:::::b
  G:::::G        G::::G i::::i      t:::::t            H:::::H     H:::::H  u::::u    u::::u  b:::::b     b:::::b
   G:::::G       G::::G i::::i      t:::::t    tttttt  H:::::H     H:::::H  u:::::uuuu:::::u  b:::::b     b:::::b
    G:::::GGGGGGGG::::Gi::::::i     t::::::tttt:::::tHH::::::H     H::::::HHu:::::::::::::::uub:::::bbbbbb::::::b
     GG:::::::::::::::Gi::::::i     tt::::::::::::::tH:::::::H     H:::::::H u:::::::::::::::ub::::::::::::::::b
       GGG::::::GGG:::Gi::::::i       tt:::::::::::ttH:::::::H     H:::::::H  uu::::::::uu:::ub:::::::::::::::b
          GGGGGG   GGGGiiiiiiii         ttttttttttt  HHHHHHHHH     HHHHHHHHH    uuuuuuuu  uuuubbbbbbbbbbbbbbbb${NC}"
echo
echo
echo This script will point existing local GitLab repos to the corresponding GitHub repo.
if [[ -z "$BACKUP" ]]; then
  echo -e "${YELLOW}No backup is being taken. If you wish to do so, rerun this script specifying \`-b\`${NC}"
fi
read -p "Do you wish to continue? <y/N> " PROMPT
if [[ ${PROMPT} != "y" ]]; then
  echo exiting
  exit 1
fi

## ----------------------------------------------------------------------
## See if the DEFRA_WORKSPACE variable is set and that it is a valid path
## ----------------------------------------------------------------------
echo -e "${BLUE}Checking DEFRA_WORKSPACE variable:${NC}"
if [[ -z "${DEFRA_WORKSPACE}" ]]; then
  echo -e "${RED}You need to set the DEFRA_WORKSPACE variable${NC}"
  echo
  echo "export DEFRA_WORKSPACE=\"PATH_TO_YOUR_IMPORTS_WORKSPACE\""
  exit 1
fi
ls ${DEFRA_WORKSPACE} > /dev/null 2>&1
RET=$?
if [[ $RET -ne 0 ]]; then
  echo -e "${RED}The DEFRA_WORKSPACE variable: \"${DEFRA_WORKSPACE}\" is not a valid directory${NC}"
  exit 1
fi
echo "DEFRA_WORKSPACE variable is set to: \"${DEFRA_WORKSPACE}\""
echo

## ---------------------------
## Check the github connection
## ---------------------------
echo -e "${BLUE}:: Checking connection to GitHub${NC}"
ssh -T git@github.com > /dev/null 2>&1
RET=$?
if [[ $RET == 1 ]]; then
  echo -e "${GREEN}Authenticated - continuing${NC}"
  echo
elif [[ $RET == 255 ]]; then
  echo -e "${RED}User is not authenticated!${NC}"
  echo
  echo Please follow the instructions here to allow connecting via ssh
  echo https://docs.github.com/en/authentication/connecting-to-github-with-ssh
  echo
  echo You will need to have TFA enabled on your github account.
  echo
  echo If you would also like to sign your commits with your ssh key see instructions here:
  echo https://docs.github.com/en/authentication/managing-commit-signature-verification/telling-git-about-your-signing-key#telling-git-about-your-ssh-key
  echo
  exit 1
else
  echo -e "${RED}Unable to connect to GitHub, please check your network connection${NC}" >&2
  exit 1
fi

## -------------
## Make a backup
## ------------
if [[ "${BACKUP}" ]]; then
  DEFRA_WORKSPACE_WITHOUT_TRAILING_SLASH=$(echo "${DEFRA_WORKSPACE}" | sed 's:/*$::')
  DEFRA_WORKSPACE_BACKUP="${DEFRA_WORKSPACE_WITHOUT_TRAILING_SLASH}"-BACKUP-$(date '+%Y%m%d-%H%M%S')
  echo -e "${BLUE}:: Backing up to: ${DEFRA_WORKSPACE_BACKUP}${NC}"
  cp -R "${DEFRA_WORKSPACE_WITHOUT_TRAILING_SLASH}" "${DEFRA_WORKSPACE_BACKUP}"
fi

## ------------------------------------
## For each directory change the remote
## ------------------------------------
cd "${DEFRA_WORKSPACE}"
find -s "${DEFRA_WORKSPACE}" -type d -mindepth 1 -maxdepth 1 -print0 | while IFS= read -r -d '' DIRECTORY; do
  cd "${DIRECTORY}"
  echo -e "${BLUE}:: Currently in directory: ${DIRECTORY}${NC}"
  CURRENT_REMOTE="$(git config --get remote.origin.url)"
  CURRENT_REPO_NAME="$(repo_name_from_remote "${CURRENT_REMOTE}")"
  for IGNORE in "${NOT_TO_MIGRATE_GITLAB[@]}"; do
    if [[ "${IGNORE}" == "${CURRENT_REPO_NAME}" ]]; then
      echo -e "${YELLOW}Repo "${CURRENT_REMOTE}" is not to be migrated. Skipping.${NC}"
      echo
      continue 2
    fi
  done
  echo The current remote \`origin\` is: "${CURRENT_REMOTE}".
  if [[ -z "${CURRENT_REMOTE}" ]]; then
    echo -e "${YELLOW}This is not a git repo. Skipping.${NC}"
  elif [[ "${CURRENT_REMOTE}" == *"giteux.azure.defra.cloud:imports"* ]] && [[ -z "${REVERSE}" ]]; then
    NEW_REMOTE="$(github_remote_from_gitlab_remote "${CURRENT_REMOTE}")"
    point_to_remote "${NEW_REMOTE}"
  elif [[ "${CURRENT_REMOTE}" == *"github.com:DEFRA"* ]] && [[ "${REVERSE}" ]]; then
    NEW_REMOTE="$(gitlab_remote_from_github_remote "${CURRENT_REMOTE}")"
    point_to_remote "${NEW_REMOTE}"
  else
    echo -e "${YELLOW}Not changing the remote on repo: "${CURRENT_REPO_NAME}". Skipping.${NC}"
  fi
  cd ../
  echo
done

echo -e "${GGREEN}
________                  ______
___  __ \____________________  /
__  / / /  __ \_  __ \  _ \_  /
_  /_/ // /_/ /  / / /  __//_/
/_____/ \____//_/ /_/\___/(_)
${NC}"
