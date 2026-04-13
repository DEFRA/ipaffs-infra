targetScope = 'resourceGroup'

param acrName string
param deploymentId string
param location string
param subnets object
param tags object

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: acrName
}

resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${acrName}-${subnets.privateEndpoints.name}'
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

// vim: set ts=2 sts=2 sw=2 et:
