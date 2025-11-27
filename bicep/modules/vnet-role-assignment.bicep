targetScope = 'resourceGroup'

param deploymentId string
param principalObjectId string
param roleDefinitionId string
param vnetName string

resource vnet 'Microsoft.Network/virtualNetworks@2024-10-01' existing = {
  name: vnetName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vnet.id, roleDefinitionId, principalObjectId)
  scope: vnet
  properties: {
    principalId: principalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}

// vim: set ts=2 sts=2 sw=2 et:
