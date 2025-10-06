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

if [[ -z "${IPAFFS_KEYVAULT}" ]]; then
  echo "IPAFFS_KEYVAULT environment variable not set." >&2
  echo >&2
  echo "Please set this to name of the Key Vault from which to retrieve development secrets." >&2
  echo "e.g. \`export IPAFFS_KEYVAULT=fortknox\`" >&2
  exit 1
fi

if [[ "${http_proxy}${https_proxy}" != "" ]]; then
  echo -e "${YELLOW}Warning: You have set the \`http_proxy\` or \`https_proxy\` environment variable(s).${NC}" >&2
  echo "These will be translated and set in your IPAFFS virtual machine by Lima. This may or may not be what you want, noting that any TLS interception is likely to break provisioning of the VM. To prevent this, simply unset both of these environment variables and re-provision the VM:" >&2
  echo "  $ unset http_proxy https_proxy" >&2
  echo "  $ limactl stop ipaffs" >&2
  echo "  $ limactl delete ipaffs" >&2
  echo "  $ ${0}" >&2
  echo >&2
fi

set -e

# Check prerequisites
if ! command -v limactl >/dev/null 2>&1; then
  echo -e "${RED}Error: \`limactl\` not available in PATH. Please install Lima.${NC}" >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo -e "${RED}Error: \`kubectl\` not available in PATH. Please install Kubernetes command-line interface.${NC}" >&2
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo -e "${RED}Error: \`openssl\` not available in PATH. Please install OpenSSL.${NC}" >&2
  exit 1
fi
if ! command -v helm >/dev/null 2>&1; then
  echo -e "${RED}Error: \`helm\` not available in PATH. Please install helm.${NC}" >&2
  exit 1
fi

# Create VM using lima if not already present
if limactl list ipaffs 2>&1 | grep -q "No instance"; then
  echo -e "${BLUE}\n:: Creating virtual machine using \`limactl\`${NC}"
  [[ "$(uname)" == "Darwin" ]] && VZARGS="--vm-type=vz --rosetta"
  limactl create --name=ipaffs ${VZARGS} --tty=false "${REPO_DIR}/lima/k3s-local-dev.yaml"
fi

# Start the VM if not running
if ! limactl list ipaffs | grep -q Running; then
  echo -e "${BLUE}\n:: Starting virtual machine using \`limactl\`${NC}"
  ## allow privileged port access for none sudo user
  [[ "$(uname)" == "Linux" ]] && sudo setcap 'cap_net_bind_service=+ep' /usr/bin/ssh

  limactl start ipaffs
fi

# Generate TLS certificate and key if missing
if ! [[ -e "${REPO_DIR}/deploy/tls/imp.dev.azure.defra.cloud.pem" ]]; then
  echo -e "${BLUE}\n:: Creating self-signed wildcard certificate${NC}"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${REPO_DIR}/deploy/tls/imp.dev.azure.defra.cloud-key.pem" \
    -out "${REPO_DIR}/deploy/tls/imp.dev.azure.defra.cloud.pem" \
    -subj "/C=GB/ST=England/L=Leeds/O=DEFRA/OU=IPAFFS/CN=*.imp.dev.azure.defra.cloud"

  # Trust the certificate on macOS
  if [[ "$(uname)" == "Darwin" ]]; then
    echo -e "${BLUE}\n:: Adding the self-signed certificate to the MacOS Login Keychain${NC}"
    security -v add-trusted-cert -d -r trustRoot -k "${HOME}/Library/Keychains/login.keychain-db" "${REPO_DIR}/deploy/tls/imp.dev.azure.defra.cloud.pem"
  fi
fi

# Create persistent storage directory for registry
limactl shell ipaffs sudo mkdir -p /srv/registry

# Use correct Docker context
echo -e "${BLUE}\n:: Switching Docker context to \`lima-ipaffs\`${NC}"
docker context use lima-ipaffs

# Configure kubectl to connect to IPAFFS VM
export KUBECONFIG="${HOME}/.lima/ipaffs/copied-from-guest/kubeconfig.yaml"

# Install nginx ingress controller
echo -e "${BLUE}\n:: Installing nginx-ingress controller${NC}"
helm upgrade --install nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace kube-system --values "${REPO_DIR}/deploy/nginx-ingress/values.yaml"

# Deploy base services
echo -e "${BLUE}\n:: Deploying base services to Kubernetes${NC}"
kubectl apply -k "${REPO_DIR}/deploy"

# Create Secret for ACR token
echo -e "${BLUE}\n:: Creating Secret for ACR Token${NC}"
kubectl delete secret ipaffs-acr 2>/dev/null || true
kubectl create secret docker-registry ipaffs-acr \
    --docker-server=pocimpinfac1401.azurecr.io \
    --docker-username=ipaffs \
    --docker-password="$(az keyvault secret show --vault-name "${IPAFFS_KEYVAULT}" -n ipaffsAcrTokenPassword --query value -o tsv)"

# Detect docker-local directory
if [[ -d "${IMPORTS_DIR}/ipaffs-docker-local" ]]; then
  echo -e "${BLUE}.. using \`ipaffs-docker-local\`${NC}"
  _docker_local_dir="${IMPORTS_DIR}/ipaffs-docker-local"
elif [[ -d "${IMPORTS_DIR}/docker-local" ]]; then
  echo -e "${BLUE}.. using \`docker-local\`${NC}"
  _docker_local_dir="${IMPORTS_DIR}/docker-local"
else
  echo -e "${RED}No \`ipaffs-docker-local\` or \`docker-local\` directory was found${NC}"
  exit 1
fi

# Build SQL Server container
echo -e "${BLUE}\n:: Building database container image${NC}"
docker build --platform=linux/amd64 -t import-notification-database "${_docker_local_dir}/database"

# Tag and push database container image
echo -e "${BLUE}\n:: Pushing database container image to local registry${NC}"
docker tag import-notification-database:latest host.docker.internal:30500/import-notification-database:latest
docker push host.docker.internal:30500/import-notification-database:latest

# Done \o/
echo
echo -e "${GREEN}\n:: IPAFFS development VM is provisioned and ready to use!${NC}"
echo
echo "Don't forget to configure kubectl and docker - consider adding these to your shell profile:"
echo '  $ export KUBECONFIG="${HOME}/.lima/ipaffs/copied-from-guest/kubeconfig.yaml"'
echo '  $ export DEFRA_WORKSPACE="${HOME}/path/to/imports"'
echo

# vim: set ts=2 sts=2 sw=2 et:
