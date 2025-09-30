param name string
param location string = resourceGroup().location
param sku string = 'Premium' // Options: Basic, Standard, Premium
param adminEnabled bool = true
param subnetId string  

var acrPullRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
)

resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: name
  location: location
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: adminEnabled
  }
}

resource acrPe 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: name
  location: location
  properties: {
    subnet: {
      id: subnetId
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


resource acrPullToAks3 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acrPullRoleId, 'pool3')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: '3fa370b7-73dd-4ab3-a441-51354afb4b27'
    principalType: 'ServicePrincipal'
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output acrResourceId string = acr.id
