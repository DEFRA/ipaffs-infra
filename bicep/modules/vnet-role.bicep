targetScope = 'POCIMPNETVN1401'

param vnetName string
param roleDefinitionId string
param principalObjectId string

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: vnetName
}

resource assign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vnet.id, roleDefinitionId, principalObjectId)
  scope: vnet
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalObjectId
    principalType: 'ServicePrincipal'
  }
}