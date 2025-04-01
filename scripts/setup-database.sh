#!/bin/bash

REPO_DIR="$(cd "$(dirname $0)"/.. && pwd)"
IMPORTS_DIR="$(cd "${REPO_DIR}"/../imports && pwd)"

# DEFRA_WORKSPACE is needed by downstream setup scripts
export DEFRA_WORKSPACE="${IMPORTS_DIR}"

override_db_port() {
  export DATABASE_DB_HOST=127.0.0.1
  export DATABASE_DB_PORT=31433
  export DB_HOST=${DATABASE_DB_HOST}
  export DB_PORT=${DATABASE_DB_PORT}
  export DATABASE_DB_CONNECTION_STRING="jdbc:sqlserver://${DB_HOST}:${DB_PORT};database=${DB_NAME};encrypt=true;trustServerCertificate=${TRUST_SERVER_CERTIFICATE};hostNameInCertificate=*.database.windows.net;"
}

# Build SQL Server container
docker build --platform=linux/amd64 -t import-notification-database "${IMPORTS_DIR}/docker-local/database" 

# Tag and push database container image
docker tag import-notification-database:latest host.docker.internal:30100/import-notification-database:latest
docker push host.docker.internal:30100/import-notification-database:latest

# Start the database container
kubectl apply -f "${REPO_DIR}/deploy/database.yaml"

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
#load_all_data
