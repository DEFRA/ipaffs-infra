#!/bin/bash

set -e

AKS_RG="POCIMPINFRGP001"
BASTION_RG="bastion-rg"
BASTION_VNET="bastion-vnet"
AKS_VNET="ipaffs-vnet"

echo "🔍 Fetching VNet resource IDs..."
AKS_VNET_ID=$(az network vnet show --name $AKS_VNET --resource-group $AKS_RG --query id -o tsv)
BASTION_VNET_ID=$(az network vnet show --name $BASTION_VNET --resource-group $BASTION_RG --query id -o tsv)

echo "🔁 Creating Bastion → AKS VNet peering..."
az deployment group create \
  --resource-group $BASTION_RG \
  --template-file bastion-peering.bicep \
  --parameters aksVnetId=$AKS_VNET_ID

echo "🔁 Creating AKS → Bastion VNet peering..."
az deployment group create \
  --resource-group $AKS_RG \
  --template-file aks-peering.bicep \
  --parameters bastionVnetId=$BASTION_VNET_ID

echo "✅ VNet peering complete in both directions."