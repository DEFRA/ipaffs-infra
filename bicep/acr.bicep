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


resource acrPullToAks1 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acrPullRoleId, 'pool1')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: 'bcdcf4d5-13de-4ad1-a450-25146efe851c'
    principalType: 'ServicePrincipal'
  }
}

resource acrPullToAks1 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acrPullRoleId, 'pool2')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: 'edbbccb9-6269-43cd-ab1e-531f40df66f0'
    principalType: 'ServicePrincipal'
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output acrResourceId string = acr.id
