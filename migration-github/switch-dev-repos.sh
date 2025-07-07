echo This script will point existing local gitlab repos to the corresponding github repo.
read -p "Do you wish to continue? <y/N> " PROMPT
case $PROMPT in
        [y]* ) break;;
        * ) echo exiting; exit;;
esac

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
## For each directory change the remote.
cd $DEFRA_WORKSPACE

for DIRECTORY in */ ; do
    cd "${DIRECTORY}"
    echo Currently in directory: "${DIRECTORY}"
    CURRENT_REMOTE=$(git config --get remote.origin.url)
    if [[ "${CURRENT_REMOTE}" == *"git@giteux.azure.defra.cloud:imports"* ]]; then
      CURRENT_REPO_NAME=$(echo ${CURRENT_REMOTE} | sed 's:.*/::')
      echo The current remote is: "${CURRENT_REMOTE}".
      NEW_REMOTE="git@github.com:DEFRA/ipaffs-${CURRENT_REPO_NAME}"
      read -p "The new remote will be: "${NEW_REMOTE}". Do you wish to continue? <y/N> " PROMPT
      case $PROMPT in
              [y]* )
                git remote set-url origin ${NEW_REMOTE}
                echo Switched remote to ${NEW_REMOTE} continuing;;
              * )
                echo Leaving remote as ${CURRENT_REMOTE}. Continuing;;
      esac
    else
      echo The current remote is not pointing at git lab or this is not a git repo. Continuing.
    fi
    echo
    cd ../
done



