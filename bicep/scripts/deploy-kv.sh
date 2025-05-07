#!/bin/bash

set -e

# === Configurable Variables ===
KV_NAME="ipaffs-keyvault"
LOCATION="northeurope"
AKS_RG="POCIMPINFRGP001"
VNET_RG="POCIMPINFRGP001"
VNET_NAME="ipaffs-vnet"
SUBNET_NAME="aks-subnet"
DNS_ZONE_NAME="privatelink.vaultcore.azure.net"

# === Identity of the user or automation
TENANT_ID=$(az account show --query tenantId -o tsv)
OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

echo "🔐 Deploying private Key Vault with private endpoint and DNS..."

az deployment group create \
  --resource-group $AKS_RG \
  --template-file keyvault.bicep \
  --parameters \
    name=$KV_NAME \
    location=$LOCATION \
    tenantId=$TENANT_ID \
    objectId=$OBJECT_ID \
    vnetResourceGroup=$VNET_RG \
    vnetName=$VNET_NAME \
    subnetName=$SUBNET_NAME \
    dnsZoneName=$DNS_ZONE_NAME

echo "✅ Key Vault '$KV_NAME' deployed in '$LOCATION'."
