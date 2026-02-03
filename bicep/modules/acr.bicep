targetScope = 'resourceGroup'

param acrParams object
param deploymentId string
param location string
param subnetIds array
param subnetNames object
param tags object

var subnetId = first(filter(subnetIds, subnetId => contains(subnetId, subnetNames.privateEndpoints)))

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
  name: '${acrParams.name}-${last(split(subnetId, '/'))}'
  location: location
  tags: tags

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

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer

// vim: set ts=2 sts=2 sw=2 et:
