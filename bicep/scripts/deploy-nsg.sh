#!/bin/bash

set -e

# AKS_RG="POCIMPINFRGP001"
# BASTION_RG="bastion-rg"
# BASTION_VNET="bastion-vnet"
# AKS_VNET="ipaffs-vnet"
NW_NSG="POCIMPNETNS1401"

echo "🔁 Deploying NSGs..."
az deployment group create \
  --resource-group $NW_RG \
  --template-file network-security-group.bicep \
  --parameters @network-security-group.parameters.json

echo "✅ NSGs Deployed."