importsDirectory=$DEFRA_WORKSPACE
services="bip-microservice
bordernotification-microservice
checks-microservice
economicoperator-microservice
enotification-event-microservice
in-service-messaging-microservice
notification-microservice
soaprequest-microservice"

echo "========================================================================================================================="
echo "This script checks to see if there have been any changes to the migrations.xml of projects between releases"
echo "It only checks the projects which have a shared database. I.e. not blue or green"
echo "This should give a good indication if there are database changes which may cause issues with roll back during a release"
echo "========================================================================================================================="
echo ""
read -p "What is the previous release tag: " releaseTagBefore
read -p "What is the current release tag: " releaseTagAfter
echo ""
echo "================================================================================="
echo "= Changes to migration.xml for service with shared database (not blue or green)"
echo "= Between release $releaseTagBefore and $releaseTagAfter"
echo "================================================================================="
echo ""
echo ""
echo ""
for service in $services; do
  cd $importsDirectory
  cd pipeline-library
  git pull --quiet 2>/dev/null
  repoTagBefore=`git show $releaseTagBefore:resources/configuration/imports/deploylist/octopus/deployList.txt | grep "^$service" | sed 's/.*1\.0\.\([0-9]*\).*/\1/'`
  repoTagAfter=`git show $releaseTagAfter:resources/configuration/imports/deploylist/octopus/deployList.txt | grep "^$service" | sed 's/.*1\.0\.\([0-9]*\).*/\1/'`
  echo "================================================================================="
  echo "= Service: $service"
  echo "= In release: $releaseTagBefore has tag: $repoTagBefore"
  echo "= In release: $releaseTagAfter has tag: $repoTagAfter"
  cd $importsDirectory/$service
  git pull --quiet 2>/dev/null
  migrations=`find * -name "migrations.xml"`
  for migration in $migrations; do
      changes=`  git --no-pager diff "refs/tags/"$repoTagAfter.."refs/tags/"$repoTagBefore -- $migration 2>/dev/null`
      if [[ "$changes" != "" ]]; then
         echo "= THERE ARE CHANGES in $migration"
         echo "= To see the changes: "
         echo "= cd $PWD"
         echo "= git pull"
         echo "= git diff refs/tags/$repoTagAfter..refs/tags/$repoTagBefore -- $migration"
      else
        echo "= There are no changes in $migration"
      fi
  done
  echo "================================================================================="
  echo ""
  echo ""
  echo ""
done
