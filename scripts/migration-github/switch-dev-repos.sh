#!/bin/bash

set -e

readonly RED='\033[0;31m'
readonly RRED='\033[0;91m'
readonly GREEN='\033[0;32m'
readonly GGREEN='\033[0;92m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

NOT_TO_MIGRATE_GITLAB=(
  "ansible" ## Not to migrate
  "ansible-jenkins" ## Not to migrate
  "terraform" ## Not to migrate
)

RECLONE_REPOS=(
  "docker-local" ## LFS
  "fieldconfig-microservice" ## LFS
  "files" "ipaffs-files" ## LFS
  "referencedata-microservice" ## LFS
  "scrapy-traces" ## LFS
)

RENAME_REPOS=(
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
  for RENAME_REPO in "${RENAME_REPOS[@]}"
  do
    REPO=(${RENAME_REPO//,/ })
    if [[ "${NAME}" == "${REPO[0]}" ]]; then
      echo "${REPO[1]}"
      return
    fi
  done
  echo ipaffs-"${NAME}"
}

gitlab_name_from_github_name() {
  NAME="${1}"
  for RENAME_REPO in "${RENAME_REPOS[@]}"
    do
      REPO=(${RENAME_REPO//,/ })
      if [[ "${NAME}" == "${REPO[1]}" ]]; then
        echo "${REPO[0]}"
        return
      fi
  done
  echo "${NAME#*ipaffs-*}"
}

point_to_remote() {
  REMOTE_NAME="${1}"
  REMOTE_URL="${2}"
  if git remote | grep -q "^${REMOTE_NAME}$"; then
    echo -e "${BLUE}:: Setting remote \`${REMOTE_NAME}\` to: ${REMOTE_URL}${NC}"
    git remote set-url "${REMOTE_NAME}" "${REMOTE_URL}"
    git fetch --quiet "${REMOTE_NAME}" || true
    git remote prune "${REMOTE_NAME}" > /dev/null 2>&1
    echo "Remote updated"
  else
    echo -e "${BLUE}:: Adding remote \`${REMOTE_NAME}\` to point to: ${REMOTE_URL}${NC}"
    git remote add "${REMOTE_NAME}" "${REMOTE_URL}"
    git fetch --quiet "${REMOTE_NAME}" || true
    echo "Remote added"
  fi
}

remove_remote() {
  REMOTE_NAME="${1}"
  echo -e "${BLUE}:: Removing remote \`${REMOTE_NAME}\`${NC}"
  if git remote | grep -q "^${REMOTE_NAME}$"; then
    git remote remove "${REMOTE_NAME}"
    echo "Remote removed"
  else
    echo "Remote not found, skipping"
  fi
}

reclone_from_github() {
  REPO="${1}"
  REMOTE="${2}"
  echo -e "${BLUE}:: Re-cloning \`${REPO}\` from GitHub${NC}"
  [[ -d "${REPO}.backup-gitlab" ]] && rm -rf "${REPO}.backup-gitlab"
  mv -v "${REPO}" "${REPO}.backup-gitlab"
  echo "Original clone renamed"
  git clone "${NEW_REMOTE}" "${REPO}"
  echo "Repository re-cloned"
}

restore_original_clone() {
  REPO="${1}"
  echo -e "${BLUE}:: Restoring original repo: ${REPO}${NC}"
  if [[ -d "${REPO}.backup-gitlab" ]]; then
    rm -r "${REPO}"
    echo -e "Restoring backup clone of ${REPO}"
    mv "${REPO}.backup-gitlab" "${REPO}"
    echo "Clone renamed"
  else
    echo -e "${YELLOW}Warning: backup for \`${REPO}\` not found, so not deleting GitHub clone${NC}"
  fi
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
echo -e "${BLUE}:: Checking DEFRA_WORKSPACE variable:${NC}"
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
RET=0
ssh -T git@github.com > /dev/null 2>&1 || RET=$?
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
find -s "${DEFRA_WORKSPACE}" -type d -mindepth 1 -maxdepth 1 ! -name '*.backup*' -print0 | while IFS= read -r -d '' DIRECTORY; do
  cd "${DIRECTORY}"
  echo -e "${PURPLE}:: Currently in directory: ${DIRECTORY}${NC}"
  CURRENT_REMOTE="$(git config --get remote.origin.url)"
  CURRENT_REPO_NAME="$(repo_name_from_remote "${CURRENT_REMOTE}")"

  for IGNORE in "${NOT_TO_MIGRATE_GITLAB[@]}"; do
    if [[ "${IGNORE}" == "${CURRENT_REPO_NAME}" ]]; then
      echo -e "${YELLOW}Repo "${CURRENT_REMOTE}" is not to be migrated. Can't touch this.${NC}"
      echo
      continue 2
    fi
  done

  reclone=
  for RECLONE in "${RECLONE_REPOS[@]}"; do
    if [[ "${RECLONE}" == "${CURRENT_REPO_NAME}" ]] || [[ "ipaffs-${RECLONE}" == "${CURRENT_REPO_NAME}" ]]; then
      echo -e "${YELLOW}Repo "${CURRENT_REMOTE}" must be re-cloned${NC}"
      reclone=1
      break
    fi
  done

  echo The current remote \`origin\` is: "${CURRENT_REMOTE}".
  if [[ -z "${CURRENT_REMOTE}" ]]; then
    echo -e "${YELLOW}This is not a git repo. Skipping.${NC}"
  elif [[ "${CURRENT_REMOTE}" == *"giteux.azure.defra.cloud:imports"* ]] && [[ -z "${REVERSE}" ]]; then
    NEW_REMOTE="$(github_remote_from_gitlab_remote "${CURRENT_REMOTE}")"
    if [[ -n "${reclone}" ]]; then
      cd ../
      reclone_from_github "${CURRENT_REPO_NAME}" "${NEW_REMOTE}"
    else
      point_to_remote origin "${NEW_REMOTE}"
      point_to_remote gitlab "${CURRENT_REMOTE}"
      remove_remote github
      cd ../
    fi
  elif [[ "${CURRENT_REMOTE}" == *"github.com:DEFRA"* ]] && [[ "${REVERSE}" ]]; then
    NEW_REMOTE="$(gitlab_remote_from_github_remote "${CURRENT_REMOTE}")"
    if [[ -n "${reclone}" ]]; then
      cd ../
      restore_original_clone "${CURRENT_REPO_NAME}"
    else
      point_to_remote origin "${NEW_REMOTE}"
      point_to_remote github "${CURRENT_REMOTE}"
      remove_remote gitlab
      cd ../
    fi
  else
    echo -e "${YELLOW}Not changing the remote on repo: "${CURRENT_REPO_NAME}". Skipping.${NC}"
    cd ../
  fi
  echo
done

echo -e "${GGREEN}
________                  ______
___  __ \____________________  /
__  / / /  __ \_  __ \  _ \_  /
_  /_/ // /_/ /  / / /  __//_/
/_____/ \____//_/ /_/\___/(_)
${NC}"
