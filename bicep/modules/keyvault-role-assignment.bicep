targetScope = 'resourceGroup'

param keyVaultName string
param deploymentId string
param principalObjectId string
param roleDefinitionId string

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, roleDefinitionId, principalObjectId)
  scope: keyVault
  properties: {
    principalId: principalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}

// vim: set ts=2 sts=2 sw=2 et:
