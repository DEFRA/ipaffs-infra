targetScope = 'resourceGroup'

param storageAccountName string
param deploymentId string
param principalObjectId string
param principalType string
param roleDefinitionId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, roleDefinitionId, principalObjectId)
  scope: storageAccount
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}
