#!/bin/bash

REPO_DIR="$(cd "$(dirname $0)"/.. && pwd)"
IMPORTS_DIR="${DEFRA_WORKSPACE}"

if ! [[ -d "${DEFRA_WORKSPACE}" ]]; then
  echo "DEFRA_WORKSPACE environment variable not set." >&2
  echo >&2
  echo "Please set this to the directory where the \`imports\` repositories are checked out." >&2
  echo "e.g. \`export DEFRA_WORKSPACE=/path/to/imports\`" >&2
  exit 1
fi

set -e

override_db_port() {
  export DATABASE_DB_HOST=127.0.0.1
  export DATABASE_DB_PORT=31433
  export DB_HOST=${DATABASE_DB_HOST}
  export DB_PORT=${DATABASE_DB_PORT}
  export DATABASE_DB_CONNECTION_STRING="jdbc:sqlserver://${DB_HOST}:${DB_PORT};database=${DB_NAME};encrypt=true;trustServerCertificate=${TRUST_SERVER_CERTIFICATE};hostNameInCertificate=*.database.windows.net;"
}

# Check prerequisites
if ! command -v docker >/dev/null 2>&1; then
  echo "\`docker\` not available in PATH. Please install Docker CLI" >&2
  exit 1
fi
if ! command -v bcp >/dev/null 2>&1; then
  echo "\`bcp\` not available in PATH. Please install MSSQL Command Line Tools" >&2
  exit 1
fi
if ! command -v sqlcmd >/dev/null 2>&1; then
  echo "\`sqlcmd\` not available in PATH. Please install MSSQL Command Line Tools" >&2
  exit 1
fi

# Use correct Docker context
docker context use lima-ipaffs

# Build SQL Server container
docker build --platform=linux/amd64 -t import-notification-database "${IMPORTS_DIR}/docker-local/database" 

# Tag and push database container image
docker tag import-notification-database:latest host.docker.internal:30500/import-notification-database:latest
docker push host.docker.internal:30500/import-notification-database:latest

# Start the database container
kubectl apply -f "${REPO_DIR}/deploy/database/database.yaml"

# Wait for MSSQL to start up
echo "Waiting 2 minutes for database..."
sleep 120

# Source database go script and override database port number
cd "${IMPORTS_DIR}/docker-local/database"
source "${IMPORTS_DIR}/docker-local/database/go"
override_db_port

# Initialize the database
initialize_database

# Source setup script and override database port number
cd "${IMPORTS_DIR}/docker-local"
source "${IMPORTS_DIR}/docker-local/docker_setup.sh"
override_db_port

# Load data
load_all_data
