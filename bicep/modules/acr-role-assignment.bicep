targetScope = 'resourceGroup'

param acrName string
param roleDefinitionId string
param principalObjectId string

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: acrName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, roleDefinitionId, principalObjectId)
  scope: acr
  properties: {
    principalId: principalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}

// vim: set ts=2 sts=2 sw=2 et:
