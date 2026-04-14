targetScope = 'resourceGroup'

param acrParams object
param deploymentId string
param entraGroups object
param location string
param tags object

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: acrParams.name
  location: location
  tags: tags

  sku: {
    name: acrParams.sku
  }

  properties: {
    adminUserEnabled: acrParams.adminEnabled
  }
}

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

module acrPull './acr-role-assignment.bicep' = {
  name: 'acrPull-${deploymentId}'
  scope: resourceGroup()
  params: {
    acrName: acr.name
    deploymentId: deploymentId
    principalObjectId: entraGroups.acrPull.id
    principalType: 'Group'
    roleDefinitionId: acrPullRoleId
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output acrResourceId string = acr.id

// vim: set ts=2 sts=2 sw=2 et:
