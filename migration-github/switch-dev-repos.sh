echo This script will point existing local gitlab repos to the corresponding github repo.
read -p "Do you wish to continue? <y/N> " prompt
## See if the DEFRA_WORKSPACE variable is set and that it is a valid path
echo Checking DEFRA_WORKSPACE variable:
if [ -z ${DEFRA_WORKSPACE} ]; then
  echo You need to set the DEFRA_WORKSPACE variable e.g.:
  echo export DEFRA_WORKSPACE=\"PATH_TO_YOUR_IMPORTS_WORKSPACE\" - exiting
  exit 1
fi
ls ${DEFRA_WORKSPACE} > /dev/null 2>&1
RET=$?
if [ $RET -ne 0 ]; then
  echo The DEFRA_WORKSPACE variable: \"${DEFRA_WORKSPACE}\" is not a valid directory - exiting
  exit 2
fi
echo DEFRA_WORKSPACE variable is set to: \"${DEFRA_WORKSPACE}\"- continuing
echo 

## Check the github connection.
echo Checking connection to github 
ssh -T git@github.com > /dev/null 2>&1
RET=$?
if [ $RET == 1 ]; then
  echo Authenticated - continuing
elif [ $RET == 255 ]; then
  echo User is not authenicated. 
  echo Please follow the instructions here to allow connecting via ssh 
  echo https://docs.github.com/en/authentication/connecting-to-github-with-ssh
  echo You will need to have TFA enabled on your github account
  echo If you would also like to sign your commits with your ssh key see instructions here:
  echo https://docs.github.com/en/authentication/managing-commit-signature-verification/telling-git-about-your-signing-key#telling-git-about-your-ssh-key
  exit 3
else 
  echo Unable to get a connection to github exiting
  exit 4
fi

cd $DEFRA_WORKSPACE

