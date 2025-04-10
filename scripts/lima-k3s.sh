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

# Check prerequisites
if ! command -v limactl >/dev/null 2>&1; then
  echo "\`limactl\` not available in PATH. Please install Lima" >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "\`kubectl\` not available in PATH. Please install Kubernetes command-line interface" >&2
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "\`openssl\` not available in PATH. Please install OpenSSL" >&2
  exit 1
fi

# Create VM using lima if not already present
if limactl list ipaffs 2>&1 | grep -q "No instance"; then
  [[ "$(uname)" == "Darwin" ]] && VZARGS="--vm-type=vz --rosetta"
  limactl create --name=ipaffs ${VZARGS} --tty=false "${REPO_DIR}/lima/k3s-local-dev.yaml"
fi

# Start the VM if not running
if ! limactl list ipaffs | grep -q Running; then
  ## allow privileged port access for none sudo user
  [[ "$(uname)" == "Linux" ]] && sudo setcap 'cap_net_bind_service=+ep' /usr/bin/ssh

  limactl start ipaffs
fi

# Configure kubectl to connect to IPAFFS VM
export KUBECONFIG="${HOME}/.lima/ipaffs/copied-from-guest/kubeconfig.yaml"

# Generate TLS certificate and key if missing
if ! [[ -e "${REPO_DIR}/tls/imp.dev.azure.defra.cloud.pem" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${REPO_DIR}/tls/imp.dev.azure.defra.cloud-key.pem" \
    -out "${REPO_DIR}/tls/imp.dev.azure.defra.cloud.pem" \
    -subj "/C=GB/ST=England/L=Leeds/O=DEFRA/OU=IPAFFS/CN=*.imp.dev.azure.defra.cloud"

  # Trust the certificate on macOS
  [[ "$(uname)" == "Darwin" ]] && security add-trusted-cert -d -r trustRoot -k "${HOME}/Library/Keychains/login.keychain-db" "${REPO_DIR}/tls/imp.dev.azure.defra.cloud.pem"
fi

# Create kubernetes secrets
kubectl create secret tls ipaffs-tls --cert "${REPO_DIR}/tls/imp.dev.azure.defra.cloud.pem" \
  --key "${REPO_DIR}/tls/imp.dev.azure.defra.cloud-key.pem" --dry-run=client -o yaml | kubectl apply -f -

# Create persistent storage directory for registry
limactl shell ipaffs sudo mkdir -p /srv/registry

# Deploy a registry service
kubectl apply -f "${REPO_DIR}/deploy/registry.yaml"

# Configure service account for IPAFFS
kubectl apply -f "${REPO_DIR}/deploy/serviceaccount.yaml"

# vim: set ts=2 sts=2 sw=2 et:
