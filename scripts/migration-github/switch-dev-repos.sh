NOT_TO_MIGRATE_GITLAB=(
  "ansible", ## Not to migrate
  "ansible-jenkins", ## Not to migrate
  "terraform", ## Not to migrate
  "ArchiveNotificationFunction", ## Not to migrate
  "docker-local", ## TODO Broken
  "economicoperator-microservice", ## TODO Broken
  "fieldconfig-microservice", ## TODO Broken
  "ipaffs-files", ## TODO Broken
  "referencedata-microservice", ## TODO Broken
  "scrapy-traces" ## TODO Broken
  "imports-notification-schema", ## TODO Public
  "notify-microservice", ## TODO Public
  "soaprequest-microservice", ## TODO Public
  "spring-boot-common", ## TODO Public
  "spring-boot-common-security", ## TODO Public
  "spring-boot-parent", ## TODO Public
)

SPECIAL_CASES=(
  "import-notification-schema,ipaffs-x-import-notification-schema"
)

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

## -------------------
## Start of the script
## -------------------

## ---------------
## Check for flags
## ---------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--reverse)
      REVERSE=true
      ;;
    -b|--backup)
      BACKUP=true
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

## -------------
## Warn the user
## -------------
echo This script will point existing local gitlab repos to the corresponding github repo and switch from master to main.
if [[ -z "$BACKUP" ]]; then
  echo No backup is being taken. If you wish to do so retun this script with the backup flag set.
fi
read -p "Do you wish to continue? <y/N> " PROMPT
if [[ ${PROMPT} != "y" ]]; then
  echo exiting;
  exit
fi

## ----------------------------------------------------------------------
## See if the DEFRA_WORKSPACE variable is set and that it is a valid path
## ----------------------------------------------------------------------
echo Checking DEFRA_WORKSPACE variable:
if [[ -z "${DEFRA_WORKSPACE}" ]]; then
  echo You need to set the DEFRA_WORKSPACE variable e.g.:
  echo export DEFRA_WORKSPACE=\"PATH_TO_YOUR_IMPORTS_WORKSPACE\" - exiting
  exit
fi
ls ${DEFRA_WORKSPACE} > /dev/null 2>&1
RET=$?
if [[ $RET -ne 0 ]]; then
  echo The DEFRA_WORKSPACE variable: \"${DEFRA_WORKSPACE}\" is not a valid directory - exiting
  exit
fi
echo DEFRA_WORKSPACE variable is set to: \"${DEFRA_WORKSPACE}\"- continuing
echo

## ---------------------------
## Check the github connection
## ---------------------------
echo Checking connection to github 
ssh -T git@github.com > /dev/null 2>&1
RET=$?
if [[ $RET == 1 ]]; then
  echo Authenticated - continuing
  echo
elif [[ $RET == 255 ]]; then
  echo User is not authenicated. 
  echo Please follow the instructions here to allow connecting via ssh 
  echo https://docs.github.com/en/authentication/connecting-to-github-with-ssh
  echo You will need to have TFA enabled on your github account
  echo If you would also like to sign your commits with your ssh key see instructions here:
  echo https://docs.github.com/en/authentication/managing-commit-signature-verification/telling-git-about-your-signing-key#telling-git-about-your-ssh-key
  echo exiting
  exit
else 
  echo Unable to get a connection to github exiting
  exit
fi

## -------------
## Make a backup
## ------------
if [[ "${BACKUP}" ]]; then
  DEFRA_WORKSPACE_WITHOUT_TRALING_SLASH=$(echo "${DEFRA_WORKSPACE}" | sed 's:/*$::')
  DEFRA_WORKSPACE_BACKUP="${DEFRA_WORKSPACE_WITHOUT_TRALING_SLASH}"-BACKUP-$(date '+%Y%m%d-%H%M%S')
  echo Backing up to: "${DEFRA_WORKSPACE_BACKUP}"
  cp -R "${DEFRA_WORKSPACE_WITHOUT_TRALING_SLASH}" "${DEFRA_WORKSPACE_BACKUP}"
fi

## ------------------------------------
## For each directory change the remote
## ------------------------------------
cd "${DEFRA_WORKSPACE}"
for DIRECTORY in */ ; do
    cd "${DIRECTORY}"
    echo Currently in directory: "${DIRECTORY}"
    CURRENT_REMOTE=$(git config --get remote.origin.url)
    CURRENT_REPO_NAME=$(repo_name_from_remote "${CURRENT_REMOTE}")
    echo The current remote is: "${CURRENT_REMOTE}".
    if [[ -z "${CURRENT_REMOTE}" ]]; then
      echo This is not a git repo. Skipping.
    elif [[ "${NOT_TO_MIGRATE_GITLAB[@]}" =~ "${CURRENT_REPO_NAME}" ]]; then
      echo Repo "${CURRENT_REMOTE}" is not to be migrated. Skipping.
    elif [[ "${CURRENT_REMOTE}" == *"giteux.azure.defra.cloud:imports"* ]] && [[ -z "${REVERSE}" ]]; then
      NEW_REMOTE=$(github_remote_from_gitlab_remote "${CURRENT_REMOTE}")
      git remote set-url origin "${NEW_REMOTE}"
      git branch -m master main --quiet
      git fetch --quiet
      git branch -u origin/main main
      git remote prune origin > /dev/null 2>&1
      echo The new remote is now: "${NEW_REMOTE}", master has been renamed to main and track origin main.
    elif [[ "${CURRENT_REMOTE}" == *"github.com:DEFRA"* ]] && [[ "${REVERSE}" ]]; then
      NEW_REMOTE=$(gitlab_remote_from_github_remote "${CURRENT_REMOTE}")
      git remote set-url origin "${NEW_REMOTE}"
      git branch -m main master --quiet
      git fetch --quiet
      git branch -u origin/master master
      git remote prune origin > /dev/null 2>&1
      echo The new remote is now: "${NEW_REMOTE}", main has been renamed to master and track origin master.
    else
      echo Not chaging the remote on repo: "${CURRENT_REPO_NAME}". Skipping.
    fi
    cd ../
    echo
done