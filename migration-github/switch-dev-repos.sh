NOT_TO_MIGRATE=(
"git@giteux.azure.defra.cloud:imports/ansible.git",
"git@giteux.azure.defra.cloud:imports/ansible-jenkins.git",
"git@giteux.azure.defra.cloud:imports/terraform.git",
"git@giteux.azure.defra.cloud:imports/ArchiveNotificationFunction.git"
)

echo This script will point existing local gitlab repos to the corresponding github repo.
read -p "Do you wish to continue? <y/N> " PROMPT
if [[ "${PROMPT}" -ne "y" ]]; then
  echo exiting;
  exit
fi

## See if the DEFRA_WORKSPACE variable is set and that it is a valid path
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
echo Making a backup.
DEFRA_WORKSPACE_WITHOUT_TRALING_SLASH=$(echo ${DEFRA_WORKSPACE} | sed 's:/*$::')
cp -R "${DEFRA_WORKSPACE_WITHOUT_TRALING_SLASH}" "${DEFRA_WORKSPACE_WITHOUT_TRALING_SLASH}"-BACKUP

## TODO remove below
cd /home/richard/Desktop/imports
## TODO remove above

## For each directory change the remote.
cd "${DEFRA_WORKSPACE}"
for DIRECTORY in */ ; do
    cd "${DIRECTORY}"
    echo Currently in directory: "${DIRECTORY}"
    CURRENT_REMOTE=$(git config --get remote.origin.url)
    CURRENT_REPO_NAME=$(echo ${CURRENT_REMOTE} | sed 's:.*/::')
    echo The current remote is: "${CURRENT_REMOTE}".
    if [[ -z "${CURRENT_REMOTE}" ]]; then
      ## Not a git repo
      echo This is not a git repo. Skipping.
    elif [[ ${NOT_TO_MIGRATE[@]} =~ "${CURRENT_REMOTE}" ]]; then
      ## A git repo that we are not going to migrate.
      echo Repo "${CURRENT_REPO_NAME}" is not to be migrated. Skipping.
    elif [[ "${CURRENT_REMOTE}" == *"git@giteux.azure.defra.cloud:imports"* ]]; then
      ## The default case.
      NEW_REMOTE="git@github.com:DEFRA/ipaffs-${CURRENT_REPO_NAME}"
      ## We need to check for special case.
      if [[ "${CURRENT_REMOTE}" == "git@giteux.azure.defra.cloud:imports/import-notification-schema.git" ]]; then
        NEW_REMOTE="git@github.com:DEFRA/ipaffs-x-import-notification-schema"
      fi
      ## Set the new remote
      git remote set-url origin ${NEW_REMOTE}
      ## fetch from origin
      git fetch > /dev/null 2>&1
      RET=$?
      if [[ "${RET}" -ne 0 ]]; then
        echo There has been an error. The remote is set to ${NEW_REMOTE} but fetching failed.
      else
        ## Rename local master to main
        git branch -m master main > /dev/null 2>&1
        ## Set main to track main
        git branch -u origin/main main > /dev/null 2>&1
        echo The new remote is now "${NEW_REMOTE}", master has been renamed to main and track origin main.
      fi
    else
      echo This git repo is not set to track git lab. Skipping.
    fi
    echo
    cd ../
done