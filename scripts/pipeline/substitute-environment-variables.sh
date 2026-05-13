#!/bin/bash

## substitute-environment-variables.sh
##
## Substitutes environment variable tokens with values stored in Azure Key Vault
##
## usage $0 [env file to parse] [Azure Key Vault] [name of env file]
## Required arguments
## [$1] - The .env file to process
## [$2] - The name of the Azure Key Vault to retrieve tokens from
## [$3] - The name of .env file to output the substituted results to

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"
AKV_KEYS=$(sed -n 's/.*${\([^}]*\)}.*/\1/p' "${1}" | sort -u)

echo ":: Fetching secrets from Azure Key Vault ${2}"
for KEY in $AKV_KEYS; do
    echo ":: Retrieving key ${KEY}"
    VALUE=$(az keyvault secret show --name "${KEY}" --vault-name "${2}" --query value --output tsv 2>/dev/null)

    if [ -n "${VALUE}" ]; then
        export "${KEY}"="${VALUE}"
    else
      echo -e ":: Secret ${KEY} not found ${2}"
    fi
done

SHELL_FORMAT=$(printf '${%s} ' ${AKV_KEYS})
envsubst "${SHELL_FORMAT}" < "${1}" > "${3}"
echo -e ":: Writing updated environment file ${3}"
