targetScope = 'resourceGroup'

param deploymentId string
param principalObjectId string
param principalType string
param roleDefinitionId string

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, roleDefinitionId, principalObjectId)
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

// vim: set ts=2 sts=2 sw=2 et:
