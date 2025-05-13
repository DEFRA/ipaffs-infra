#!/bin/bash

# Required: set your Key Vault name and secret name
KEYVAULT_NAME="${1:-pocimpinfkv1401}"
SECRET_NAME="${2:-aks-ssh-public}"

echo "🔍 Fetching secret from Key Vault: $KEYVAULT_NAME / $SECRET_NAME..."

# Get the secret value
SSH_KEY=$(az keyvault secret show \
  --vault-name "$KEYVAULT_NAME" \
  --name "$SECRET_NAME" \
  --query value \
  --output tsv 2>/dev/null)

# Check if the secret was retrieved
if [[ -z "$SSH_KEY" ]]; then
  echo "❌ Secret not found or empty!"
  exit 1
fi

# Validate SSH public key format
if echo "$SSH_KEY" | grep -Eq '^ssh-(rsa|ed25519) [A-Za-z0-9+/=]+(\s.+)?$'; then
  echo "✅ SSH public key is valid."
  exit 0
else
  echo "❌ Invalid SSH public key format."
  echo "💡 Expected format: ssh-rsa or ssh-ed25519 followed by key material"
  echo "🔑 Retrieved value: $SSH_KEY"
  exit 2
fi
