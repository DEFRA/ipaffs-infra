targetScope = 'resourceGroup'

param deploymentId string
param entraGroups object
param location string
param sqlParams object
param subnetNames object
param subnets array
param tags object
param tenantId string

var subnet = first(filter(subnets, subnet => subnet.name == subnetNames.privateEndpoints))

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
      login: entraGroups.sqlAdmins.name
      principalType: 'Group'
      sid: entraGroups.sqlAdmins.id
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

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${sqlParams.serverName}-${subnet.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnet.id
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

output sqlServerName string = sqlServer.name
output sqlServerManagedIdentityObjectId string = sqlServer.identity.principalId

// vim: set ts=2 sts=2 sw=2 et:
