#!/bin/bash

REPO_DIR="$(cd "$(dirname $0)"/.. && pwd)"
IMPORTS_DIR="${DEFRA_WORKSPACE}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if ! [[ -d "${DEFRA_WORKSPACE}" ]]; then
  echo -e "${RED}Error: DEFRA_WORKSPACE environment variable not set.${NC}" >&2
  echo "Please specify the directory where the \`imports\` repositories are checked out, using the \`DEFRA_WORKSPACE\` environment variable." >&2
  echo "e.g. \`export DEFRA_WORKSPACE=/path/to/imports\`" >&2
  echo >&2
  exit 1
fi

set -e

export_db_conn() {
  export _DB_USER="sa"
  export _DB_PASS="dockerPassword1!"
  export DB_HOST="127.0.0.1"
  export DB_PORT=31433
  export DATABASE_DB_HOST="${DB_HOST}"
  export DATABASE_DB_PORT="${DB_PORT}"
  export DATABASE_DB_CONNECTION_STRING="jdbc:sqlserver://${DB_HOST}:${DB_PORT};database=${DB_NAME};encrypt=true;trustServerCertificate=true;"
}

# Check prerequisites
if ! command -v docker >/dev/null 2>&1; then
  echo "${RED}Error: \`docker\` not available in PATH. Please install Docker CLI.${NC}" >&2
  exit 1
fi
if ! command -v bcp >/dev/null 2>&1; then
  echo "${RED}Error: \`bcp\` not available in PATH. Please install MSSQL Command Line Tools.${NC}" >&2
  exit 1
fi
if ! command -v sqlcmd >/dev/null 2>&1; then
  echo "${RED}Error:\`sqlcmd\` not available in PATH. Please install MSSQL Command Line Tools.${NC}" >&2
  exit 1
fi

# Use correct Docker context
echo -e "${BLUE}:: Switching Docker context to \`lima-ipaffs\`${NC}"
docker context use lima-ipaffs

# Build SQL Server container
echo -e "${BLUE}:: Building database container image${NC}"
docker build --platform=linux/amd64 -t import-notification-database "${IMPORTS_DIR}/docker-local/database"

# Tag and push database container image
echo -e "${BLUE}:: Pushing database container image to local registry${NC}"
docker tag import-notification-database:latest host.docker.internal:30500/import-notification-database:latest
docker push host.docker.internal:30500/import-notification-database:latest

# Start the database container
echo -e "${BLUE}:: Deploying the database service${NC}"
kubectl apply -f "${REPO_DIR}/deploy/database/database.yaml"

# Wait for MSSQL to start up
echo -e "${BLUE}:: Waiting for database to become available${NC}"
export_db_conn
_starttime="$(date +%s)"
while true; do
  if sqlcmd -S "${DB_HOST},${DB_PORT}" -U "${_DB_USER}" -P "${_DB_PASS}" -Q "SELECT 1;" 2>/dev/null 1>/dev/null; then
    echo -e "${GREEN}Database server is available${NC}"
    break
  fi
  _curtime="$(date +%s)"
  if [[ $((_curtime - _starttime)) -ge 300 ]]; then
    echo -e "${RED}Error: Database service is not available.${NC}" >&2
    exit 1
  fi
  sleep 5
done

# Source database go script and override database port number
cd "${IMPORTS_DIR}/docker-local/database"
source "${IMPORTS_DIR}/docker-local/database/go"
export_db_conn

# Initialize the database
echo -e "${BLUE}:: Initializing IPAFFS database${NC}"
initialize_database

# Source setup script and override database port number
cd "${IMPORTS_DIR}/docker-local"
source "${IMPORTS_DIR}/docker-local/docker_setup.sh"
export_db_conn

# Load data
echo -e "${BLUE}:: Loading fixture data${NC}"
load_all_data

# Done \o/
echo -e "${GREEN}:: IPAFFS Database creation is complete!${NC}"

# vim: set ts=2 sts=2 sw=2 et:
