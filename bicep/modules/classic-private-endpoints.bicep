targetScope = 'resourceGroup'

param classicResourceIds object
param deploymentId string
param location string
param subnets object
param tags object

resource redisPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${last(split(classicResourceIds.redis, '/'))}-${subnets.privateEndpoints.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnets.privateEndpoints.id
    }

    privateLinkServiceConnections: [
      {
        name: 'classic-redis-connection'
        properties: {
          privateLinkServiceId: classicResourceIds.redis
          groupIds: ['redisCache']
        }
      }
    ]
  }
}

// TODO: This is disabled to prevent breaking connectivity to classic apps - we will use service endpoints as temporary workaround
//resource searchServicePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
//  name: '${last(split(classicResourceIds.searchService, '/'))}-${subnets.privateEndpoints.name}'
//  location: location
//  tags: tags
//
//  properties: {
//    subnet: {
//      id: subnets.privateEndpoints.id
//    }
//
//    privateLinkServiceConnections: [
//      {
//        name: 'classic-search-connection'
//        properties: {
//          privateLinkServiceId: classicResourceIds.searchService
//          groupIds: ['searchService']
//        }
//      }
//    ]
//  }
//}

// TODO: This is disabled to prevent breaking connectivity to classic apps - we will use service endpoints as temporary workaround
//resource serviceBusPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
//  name: '${last(split(classicResourceIds.serviceBusNamespace, '/'))}-${subnets.privateEndpoints.name}'
//  location: location
//  tags: tags
//
//  properties: {
//    subnet: {
//      id: subnets.privateEndpoints.id
//    }
//
//    privateLinkServiceConnections: [
//      {
//        name: 'classic-servicebus-connection'
//        properties: {
//          privateLinkServiceId: classicResourceIds.serviceBusNamespace
//          groupIds: ['namespace']
//        }
//      }
//    ]
//  }
//}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${last(split(classicResourceIds.sqlServer, '/'))}-${subnets.privateEndpoints.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnets.privateEndpoints.id
    }

    privateLinkServiceConnections: [
      {
        name: 'classic-sql-connection'
        properties: {
          privateLinkServiceId: classicResourceIds.sqlServer
          groupIds: ['sqlServer']
        }
      }
    ]
  }
}

// vim: set ts=2 sts=2 sw=2 et:
