#!/bin/bash

set -e

# === Configuration ===
AKS_RG_NAME="POCIMPINFRGP001"
LOCATION="northeurope"
#DNS_PREFIX="ipaffsaks"
#ADMIN_USERNAME="ipaffsadmin"
#SSH_KEY_PATH="$HOME/defra/ipaffs-infra/bicep/aks_id_rsa.pub"

# === Resource Group for actual AKS and network resources ===
echo "🔧 Ensuring AKS resource group exists: $AKS_RG_NAME"
az group create --name $AKS_RG_NAME --location $LOCATION >/dev/null
echo "✅ Resource group '$AKS_RG_NAME' is ready."

# === Deploy main.bicep which triggers network + AKS module ===
echo "🚀 Deploying Bicep templates to $AKS_RG_NAME..."
<<'END'
az deployment group create \
  --resource-group $AKS_RG_NAME \
  --template-file main.bicep \
  --parameters dnsPrefix=$DNS_PREFIX \
               linuxAdminUsername=$ADMIN_USERNAME \
               sshRSAPublicKey="$(cat $SSH_KEY_PATH)" \
               location=$LOCATION \
               aksResourceGroupName=$AKS_RG_NAME \
  --output json | tee deployment-output.json
END

az deployment group create \
  --resource-group $AKS_RG_NAME \
  --template-file main.bicep \
  --parameters location=$LOCATION \
  --output json | tee deployment-output.json

echo "✅ Bicep deployment initiated."

# === Optional: Wait for AKS readiness ===
AKS_NAME="pocimpinfaks001"
echo "⏳ Waiting for AKS cluster '$AKS_NAME' provisioning..."

for i in {1..30}; do
  STATUS=$(az aks show --resource-group $AKS_RG_NAME --name $AKS_NAME --query provisioningState -o tsv || echo "NOT_FOUND")
  if [[ "$STATUS" == "Succeeded" ]]; then
    echo "✅ AKS cluster '$AKS_NAME' is ready."
    break
  elif [[ "$STATUS" == "Failed" ]]; then
    echo "❌ AKS provisioning failed. Check Azure Portal or run: az aks show"
    exit 1
  elif [[ "$STATUS" == "NOT_FOUND" ]]; then
    echo "🔍 AKS not yet available. Waiting..."
  else
    echo "⏳ Current provisioning state: $STATUS"
  fi
  sleep 20
done

echo "🎉 Deployment complete."
