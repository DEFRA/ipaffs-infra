NOT_TO_MIGRATE=(
"git@giteux.azure.defra.cloud:imports/ansible.git", ## Not to migrate
"git@giteux.azure.defra.cloud:imports/ansible-jenkins.git", ## Not to migrate
"git@giteux.azure.defra.cloud:imports/terraform.git", ## Not to migrate
"git@giteux.azure.defra.cloud:imports/ArchiveNotificationFunction.git", ## Not to migrate
"git@giteux.azure.defra.cloud:imports/docker-local.git", ## TODO Broken
"git@giteux.azure.defra.cloud:imports/economicoperator-microservice.git", ## TODO Broken
"git@giteux.azure.defra.cloud:imports/fieldconfig-microservice.git", ## TODO Broken
"git@giteux.azure.defra.cloud:imports/ipaffs-files.git", ## TODO Broken
"git@giteux.azure.defra.cloud:imports/referencedata-microservice.git", ## TODO Broken
"git@giteux.azure.defra.cloud:imports/scrapy-traces.git" ## TODO Broken
"git@giteux.azure.defra.cloud:imports/imports-notification-schema.git", ## TODO Public
"git@giteux.azure.defra.cloud:imports/notify-microservice.git", ## TODO Public
"git@giteux.azure.defra.cloud:imports/soaprequest-microservice.git", ## TODO Public
"git@giteux.azure.defra.cloud:imports/spring-boot-common.git", ## TODO Public
"git@giteux.azure.defra.cloud:imports/spring-boot-common-security.git", ## TODO Public
"git@giteux.azure.defra.cloud:imports/spring-boot-parent.git", ## TODO Public
)

SPECIAL_CASE=(
"import-notification-schema.git"
)

new_repo_name_from_old() {
  if [[ ${SPECIAL_CASE[@]} =~ "${1}" ]]; then
    echo "git@github.com:DEFRA/ipaffs-x-${1}"
  else
     echo "git@github.com:DEFRA/ipaffs-${1}"
  fi
}

echo This script will point existing local gitlab repos to the corresponding github repo and switch from master to main.
read -p "Do you wish to continue? <y/N> " PROMPT
if [[ "${PROMPT}" -ne "y" ]]; then
  echo exiting;
  exit
fi

## See if the DEFRA_WORKSPACE variable is set and that it is a valid path.
echo Checking DEFRA_WORKSPACE variable:
if [[ -z ${DEFRA_WORKSPACE} ]]; then
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

## Check the github connection.
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

## Make a backup.
DEFRA_WORKSPACE_WITHOUT_TRALING_SLASH=$(echo ${DEFRA_WORKSPACE} | sed 's:/*$::')
DEFRA_WORKSPACE_BACKUP="${DEFRA_WORKSPACE_WITHOUT_TRALING_SLASH}"-BACKUP-$(date '+%Y%m%d-%H%M%S')
echo Backing up to: "${DEFRA_WORKSPACE_BACKUP}"
cp -R "${DEFRA_WORKSPACE_WITHOUT_TRALING_SLASH}" "${DEFRA_WORKSPACE_BACKUP}"

## For each directory change the remote.
cd "${DEFRA_WORKSPACE}"
for DIRECTORY in */ ; do
    cd "${DIRECTORY}"
    echo Currently in directory: "${DIRECTORY}"
    CURRENT_REMOTE=$(git config --get remote.origin.url)
    echo The current remote is: "${CURRENT_REMOTE}".
    if [[ -z "${CURRENT_REMOTE}" ]]; then
      echo This is not a git repo. Skipping.
    elif [[ ${NOT_TO_MIGRATE[@]} =~ "${CURRENT_REMOTE}" ]]; then
      echo Repo "${CURRENT_REMOTE}" is not to be migrated. Skipping.
    elif [[ "${CURRENT_REMOTE}" == *"git@giteux.azure.defra.cloud:imports"* ]]; then
      CURRENT_REPO_NAME=$(echo ${CURRENT_REMOTE} | sed 's:.*/::')
      NEW_REMOTE=$(new_repo_name_from_old "${CURRENT_REPO_NAME}")
      git remote set-url origin ${NEW_REMOTE}
      git fetch --quiet
      git branch -m master main > /dev/null 2>&1 ## Fail silently if the repo does not have a master.
      git branch -u origin/main main
      echo The new remote is now "${NEW_REMOTE}", master has been renamed to main and track origin main.
    else
      echo This git repo is not set to track git lab. Skipping.
    fi
    echo
    cd ../
done