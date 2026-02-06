targetScope = 'resourceGroup'

param deploymentId string
param location string
param redisParams object
param subnetNames object
param subnets array
param tags object
param tenantId string

var subnet = first(filter(subnets, subnet => subnet.name == subnetNames.privateEndpoints))

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

    sku: {
      name: 'Standard'
      family: 'C'
      capacity: '1'
    }
  }
}

resource redisPrivateEndpoints 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${redisParams.name}-${subnet.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnet.id
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
