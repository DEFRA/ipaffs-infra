targetScope = 'resourceGroup'

param deploymentId string
param location string
param redisParams object
param subnetIds array
param tags object
param tenantId string

resource redis 'Microsoft.Search/searchServices@2025-05-01' = {
  name: redisParams.name
  location: location
  tags: tags

  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    disableAccessKeyAuthentication: false
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    redisVersion: '6.0'

    sku: {
      name: 'Standard'
      family: 'C'
      capacity: '1'
    }
  }
}

resource redisPrivateEndpoints 'Microsoft.Network/privateEndpoints@2024-10-01' = [for subnetId in subnetIds: {
  name: '${redisParams.name}-${last(split(subnetId, '/'))}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnetId
    }

    privateLinkServiceConnections: [
      {
        name: 'redis-connection'
        properties: {
          privateLinkServiceId: redis.id
          groupIds: ['redisCache']
        }
      }
    ]
  }
}]

output redisName string = redis.name
output redisId string = redis.id
