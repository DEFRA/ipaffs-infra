targetScope = 'resourceGroup'

param deploymentId string
param newLocation string
param serviceBusParams object
param subnets object
param tags object

// API version matches ARM template at https://defradev.visualstudio.com/DEFRA-Infrastructure/_git/DEFRA-EUX-IMP?path=/database/sql.json
resource sbNamespace 'Microsoft.ServiceBus/namespaces@2022-01-01-preview' existing = {
  name: serviceBusParams.namespaceName
}

resource sbPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${serviceBusParams.namespaceName}-${subnets.privateEndpoints.name}'
  location: newLocation
  tags: tags

  properties: {
    subnet: {
      id: subnets.privateEndpoints.id
    }

    privateLinkServiceConnections: [
      {
        name: 'servicebus-connection'
        properties: {
          privateLinkServiceId: sbNamespace.id
          groupIds: ['namespace']
        }
      }
    ]
  }
}

// vim: set ts=2 sts=2 sw=2 et:
