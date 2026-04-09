targetScope = 'resourceGroup'

param deploymentId string
param location string
param privateEndpointsSubnet object
param serviceBusParams object
param tags object

// API version matches ARM template at https://defradev.visualstudio.com/DEFRA-Infrastructure/_git/DEFRA-EUX-IMP?path=/database/sql.json
resource sbNamespace 'Microsoft.ServiceBus/namespaces@2022-01-01-preview' existing = {
  name: serviceBusParams.namespaceName
  location: location
}

resource sbPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${serviceBusParams.namespaceName}-${privateEndpointsSubnet.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }

    privateLinkServiceConnections: [
      {
        name: 'sql-connection'
        properties: {
          privateLinkServiceId: sbNamespace.id
          groupIds: [
            'namespace'
          ]
        }
      }
    ]
  }
}

// vim: set ts=2 sts=2 sw=2 et:
