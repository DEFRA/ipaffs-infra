targetScope = 'resourceGroup'

param acrParams object
param deploymentId string
param entraGroups object
param location string
param subnets object
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

resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: format('{0}-{1}', acrParams.name, subnets.privateEndpoints.name)
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnets.privateEndpoints.id
    }

    privateLinkServiceConnections: [
      {
        name: 'acr-connection'
        properties: {
          privateLinkServiceId: acr.id
          groupIds: [
            'registry'
          ]
        }
      }
    ]
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

var contributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

module acrContributor './acr-role-assignment.bicep' = [for principalId in acrParams.principalsNeedingContributor: {
  name: format('acrContributor-{0}-{1}', deploymentId, substring(uniqueString(principalId), 0, 7))
  scope: resourceGroup()
  params: {
    acrName: acr.name
    deploymentId: deploymentId
    principalObjectId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributorRoleId
  }
}]

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output acrResourceId string = acr.id

// vim: set ts=2 sts=2 sw=2 et:
