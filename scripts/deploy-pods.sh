#!/usr/bin/env bash

IMPORTS_DIR="${DEFRA_WORKSPACE}"

VERBOSE=false

while getopts "v" opt; do
  case $opt in
    v)
      VERBOSE=true
      ;;
    *)
      echo "Usage: $0 [-v]"
      exit 1
      ;;
  esac
done

SERVICES=("imports-proxy" "bip-microservice" "countries-microservice" "customer-microservice" "customer-wiremock-microservice" "rds-wiremock-microservice" "notification-microservice" "frontend-notification" "permissions" "frontend-control" "risk-assessment-microservice" "fieldconfig-microservice" "file-upload-microservice" "commoditycode-microservice" "frontend-upload" "checks-microservice" "economicoperator-microservice" "in-service-messaging-microservice" "frontend-decision", "cloning-microservice")
for service in "${SERVICES[@]}"; do
  echo ":: Deploying pod for $service..."
  cd "$IMPORTS_DIR/$service" || { echo "Failed to cd into $service"; exit 1; }
  if [ "$VERBOSE" = true ]; then
    git pull && git checkout spike/dev-containers
    ./scripts/build.sh && ./scripts/deploy.sh
  else
    git checkout spike/dev-containers >/dev/null 2>&1 && git pull >/dev/null 2>&1
    ./scripts/build.sh >/dev/null 2>&1 && ./scripts/deploy.sh >/dev/null 2>&1
  fi
  echo ":: Deployed pod for $service"
done
