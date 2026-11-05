targetScope = 'resourceGroup'

param deploymentId string
param location string
param redisParams object
param subnets object
param tags object
param tenantId string

resource redis 'Microsoft.Cache/redis@2024-11-01' = {
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
    updateChannel: 'Stable'

    // Require automatic zone allocation for existing and newly created caches.
    zonalAllocationPolicy: 'Automatic'

    // Current Standard C1 reservations in MB; review these when changing the SKU or size.
    redisConfiguration: {
      'maxmemory-reserved': '125'
      'maxmemory-delta': '125'
      'maxfragmentationmemory-reserved': '125'
    }

    sku: {
      name: 'Standard'
      family: 'C'
      capacity: 1
    }
  }
}

resource redisPrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-03-01' = {
  name: '${redisParams.name}-${subnets.privateEndpoints.name}'
  location: location
  tags: tags

  properties: {
    ipVersionType: 'IPv4'
    subnet: {
      id: subnets.privateEndpoints.id
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
}

output redisName string = redis.name
output redisId string = redis.id
