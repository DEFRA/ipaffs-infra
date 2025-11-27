targetScope = 'resourceGroup'

param roleDefinitionId string
param principalObjectId string

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalObjectId, roleDefinitionId)
  properties: {
    principalId: principalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}
