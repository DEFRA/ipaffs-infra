#!/bin/bash

REPO_DIR="$(cd "$(dirname $0)"/.. && pwd)"
IMPORTS_DIR="$(cd "${REPO_DIR}"/../imports && pwd)"

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
  limactl create --name=ipaffs --vm-type=vz --rosetta --tty=false "${REPO_DIR}/lima/k3s-local-dev.yaml"
fi

# Start the VM if not running
if ! limactl list ipaffs | grep -q Running; then
  limactl start ipaffs
fi

# Configure kubectl to connect to IPAFFS VM
export KUBECONFIG="/${HOME}/.lima/ipaffs/copied-from-guest/kubeconfig.yaml"

# Generate TLS certificate and key if missing
[[ -e "${REPO_DIR}/tls/traefik.pem" ]] || \
  openssl req -x509 -nodes -newkey rsa:2048 -keyout "${REPO_DIR}/tls/traefik-key.pem" -out "${REPO_DIR}/tls/traefik.pem" \
    -days 3650 -subj "/C=GB/ST=England/L=Leeds/O=DEFRA/OU=IPAFFS/CN=*.local.imp.azure.defra.cloud"

# Create kubernetes secrets
kubectl create secret tls imports-proxy-tls --cert "${REPO_DIR}/tls/traefik.pem" \
  --key "${REPO_DIR}/tls/traefik-key.pem" --dry-run=client -o yaml | kubectl apply -f -

# Configure Traefik ingress controller
#kubectl apply -f "${REPO_DIR}/deploy/traefik.yaml"

# Create persistent storage directory for registry
limactl shell ipaffs sudo mkdir -p /srv/registry

# Deploy a registry service
kubectl apply -f "${REPO_DIR}/deploy/registry.yaml"

# vim: set ts=2 sts=2 sw=2 et:
