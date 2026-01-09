targetScope = 'resourceGroup'

param searchServiceName string
param deploymentId string
param principalObjectId string
param principalType string
param roleDefinitionId string

resource searchService 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: searchServiceName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, roleDefinitionId, principalObjectId)
  scope: searchService
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

// vim: set ts=2 sts=2 sw=2 et:
