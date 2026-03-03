targetScope = 'resourceGroup'

param aksName string
param deploymentId string
param principalObjectId string
param principalType string
param roleDefinitionId string

resource aks 'Microsoft.ContainerService/managedClusters@2025-10-01' existing = {
  name: aksName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aks.id, roleDefinitionId, principalObjectId)
  scope: aks
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

// vim: set ts=2 sts=2 sw=2 et:
