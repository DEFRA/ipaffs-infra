#!/bin/bash

set -e

KV_NAME="ipaffs-keyvault"
SECRET_NAME="aks-ssh-public"
PUB_KEY_PATH="$HOME/defra/ipaffs-infra/bicep/aks_id_rsa.pub"

if [[ ! -f "$PUB_KEY_PATH" ]]; then
  echo "❌ SSH public key not found at $PUB_KEY_PATH"
  exit 1
fi

echo "📥 Uploading SSH public key to Key Vault '$KV_NAME' as secret '$SECRET_NAME'..."

az keyvault secret set \
  --vault-name $KV_NAME \
  --name $SECRET_NAME \
  --file "$PUB_KEY_PATH"

echo "✅ SSH public key uploaded successfully."
