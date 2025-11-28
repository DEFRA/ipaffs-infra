targetScope = 'resourceGroup'

param deploymentId string
param location string
param sqlParams object
param subnetIds array
param tags object
param tenantId string

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: sqlParams.serverName
  location: location
  tags: tags

  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: sqlParams.adminGroupName
      principalType: 'Group'
      sid: sqlParams.adminGroupObjectId
      tenantId: tenantId
    }
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    restrictOutboundNetworkAccess: 'Disabled'
  }
}

resource elasticPool 'Microsoft.Sql/servers/elasticPools@2023-08-01' = {
  parent: sqlServer
  name: sqlParams.elasticPoolName
  location: location
  tags: tags

  properties: {
    licenseType: 'BasePrice'
    maxSizeBytes: sqlParams.maxSizeGiB * 1024 * 1024 * 1024
    perDatabaseSettings: {
      autoPauseDelay: -1
      minCapacity: 0
      maxCapacity: sqlParams.vCores
    }
    zoneRedundant: false
  }

  sku: {
    name: 'GP_Gen5'
    capacity: sqlParams.vCores
    tier: 'GeneralPurpose'
  }
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = [for subnetId in subnetIds: {
  name: '${sqlParams.serverName}-${last(split(subnetId, '/'))}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnetId
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
}]

output sqlAdminGroupId string = sqlServer.properties.administrators.sid
output sqlServerName string = sqlServer.name

// vim: set ts=2 sts=2 sw=2 et:
