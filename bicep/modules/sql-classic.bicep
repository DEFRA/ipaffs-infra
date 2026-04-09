targetScope = 'resourceGroup'

param deploymentId string
param location string
param privateEndpointsSubnet object
param sqlAdminsEntraGroup object
param sqlParams object
param tags object
param tenantId string

// API version matches ARM template at https://defradev.visualstudio.com/DEFRA-Infrastructure/_git/DEFRA-EUX-IMP?path=/database/sql.json
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: sqlParams.serverName
  location: location

  properties: {
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: sqlAdminsEntraGroup.name
      principalType: 'Group'
      sid: sqlAdminsEntraGroup.id
      tenantId: tenantId
    }
  }
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${sqlParams.serverName}-${privateEndpointsSubnet.name}'
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
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

// vim: set ts=2 sts=2 sw=2 et:
