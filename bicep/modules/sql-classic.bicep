targetScope = 'resourceGroup'

param deploymentId string
param entraGroups object
param location string
param newLocation string
param sqlParams object
param subnets object
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
      login: entraGroups.sqlAdmins.name
      principalType: 'Group'
      sid: entraGroups.sqlAdmins.id
      tenantId: tenantId
    }
    minimalTlsVersion: '1.2'
  }
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${sqlParams.serverName}-${subnets.privateEndpoints.name}'
  location: newLocation
  tags: tags

  properties: {
    subnet: {
      id: subnets.privateEndpoints.id
    }

    privateLinkServiceConnections: [
      {
        name: 'sql-connection'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: ['sqlServer']
        }
      }
    ]
  }
}

// vim: set ts=2 sts=2 sw=2 et:
