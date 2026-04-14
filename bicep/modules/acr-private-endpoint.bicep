targetScope = 'resourceGroup'

param acrResourceId string
param deploymentId string
param location string
param subnets object
param tags object

resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${last(split(acrResourceId, '/'))}-${subnets.privateEndpoints.name}'
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
          privateLinkServiceId: acrResourceId
          groupIds: [
            'registry'
          ]
        }
      }
    ]
  }
}

// vim: set ts=2 sts=2 sw=2 et:
