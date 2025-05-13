param keyVaultName string
param sshKeySecretName string
param sshPublicKey string

resource kv 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  name: sshKeySecretName
  parent: kv
  properties: {
    value: sshPublicKey
  }
}