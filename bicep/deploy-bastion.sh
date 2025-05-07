#!/bin/bash

set -e

BASTION_RG="bastion-rg"
LOCATION="northeurope"

echo "🔧 Creating Bastion resource group..."
az group create --name $BASTION_RG --location $LOCATION

echo "🚀 Deploying Azure Bastion to $BASTION_RG..."
az deployment group create \
  --resource-group $BASTION_RG \
  --template-file bastion.bicep \
  --parameters \
    location=$LOCATION \
    bastionVnetName=bastion-vnet

echo "✅ Azure Bastion deployment complete."
