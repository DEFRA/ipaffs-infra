#!/bin/bash

set -e

AKS_RG="POCIMPINFRGP001"
LOCATION="uksouth"
VNET_NAME="ipaffs-vnet"
SUBNET_NAME="aks-subnet"
VM_NAME="aks-jumpbox"
USERNAME="jumpadmin"

# Ask user for a password securely
read -s -p "🔐 Enter admin password for jumpbox: " ADMIN_PASSWORD
echo

echo "🚀 Deploying jumpbox VM into $AKS_RG..."
az deployment group create \
  --resource-group $AKS_RG \
  --template-file jumpbox.bicep \
  --parameters \
    location=$LOCATION \
    vnetName=$VNET_NAME \
    subnetName=$SUBNET_NAME \
    vmName=$VM_NAME \
    adminUsername=$USERNAME \
    adminPassword=$ADMIN_PASSWORD

echo "✅ Jumpbox deployed successfully. Use Bastion in the Azure Portal to connect."
