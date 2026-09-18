targetScope = 'resourceGroup'

param principalObjectId string
param roleDefinitionId string
param subnetName string
param vnetName string

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2025-05-01' existing = {
  parent: vnet
  name: subnetName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subnet.id, roleDefinitionId, principalObjectId)
  scope: subnet
  properties: {
    principalId: principalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}
