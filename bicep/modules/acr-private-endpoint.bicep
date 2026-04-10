targetScope = 'resourceGroup'

param acrName string
param deploymentId string
param location string
param subnetNames object
param subnets array
param tags object

var subnet = first(filter(subnets, subnet => subnet.name == subnetNames.privateEndpoints))

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: acrName
  location: location
}

resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${acrName}-${subnet.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnet.id
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
