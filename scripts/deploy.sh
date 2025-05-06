#!/usr/bin/env bash

IMPORTS_DIR="${DEFRA_WORKSPACE}"
HELM_PACKAGE_DIR="$(cd "$(dirname "$0")/../helm-charts" && pwd)"
COMMAND=""
VERBOSE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  echo "Usage: $0 <-b|-d> [-v]"
  echo "-b  Build IPAFFS helm packages"
  echo "-d  Deploy IPAFFS helm packages"
  echo "-v  Enable verbose output"
}

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

while getopts "bdhv" OPT; do
  case $OPT in
    b)
      COMMAND="build"
      ;;
    d)
      COMMAND="deploy"
      ;;
    h)
      usage
      exit 1
      ;;
    ?)
      exit 1
      ;;
  esac
done

if [ "$COMMAND" = "build" ]; then
  echo -e "${BLUE}\n:: Creating ipaffs-backend chart... ${YELLOW}(this operation might take a little while)${NC}"
  helm dependency update "$HELM_PACKAGE_DIR/ipaffs-backend" --burst-limit -1
  helm package "$HELM_PACKAGE_DIR/ipaffs-backend"
    echo -e "${BLUE}\n:: Creating ipaffs-frontend chart... ${YELLOW}(this operation might take a little while)${NC}"
    helm dependency update "$HELM_PACKAGE_DIR/ipaffs-frontend" --burst-limit -1
    echo -e "${BLUE}\n:: Creating ipaffs-mocks chart... ${YELLOW}(this operation might take a little while)${NC}"
    helm dependency update "$HELM_PACKAGE_DIR/ipaffs-mocks" --burst-limit -1
    echo -e "${BLUE}\n:: Creating ipaffs chart... ${YELLOW}(this operation might take a little while)${NC}"
    helm dependency update "$HELM_PACKAGE_DIR/ipaffs" --burst-limit -1 --debug
fi

if [ "$COMMAND" = "deploy" ]; then
#  helm upgrade --install --render-subchart-notes  ipaffs-backend "${HELM_PACKAGE_DIR}/ipaffs-backend" \
#    --set bip-service.webapp.image.registry=localhost:30500 \
#    --set bip-service.webapp.image.tag=latest \
#    --set bip-service.webapp.environment=dev \
#    -f "${IMPORTS_DIR}/bip-microservice/deploy/dev-secrets.yaml" \
#    -f "$HELM_PACKAGE_DIR/ipaffs-backend"/values.yaml
fi



