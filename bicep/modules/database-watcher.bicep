targetScope = 'resourceGroup'

param dbwParams object
param location string
param tags object

resource kustoCluster 'Microsoft.Kusto/Clusters@2024-04-13' = {
  name: dbwParams.kustoName
  location: location
  tags: tags
  sku: {
    name: dbwParams.kustoSku.name
    tier: dbwParams.kustoSku.tier
    capacity: dbwParams.kustoSku.capacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    trustedExternalTenants: [
      {
        value: '*'
      }
    ]
    optimizedAutoscale: {
      version: 1
      isEnabled: false
      minimum: 2
      maximum: 2
    }
    enableDiskEncryption: true
    enableStreamingIngest: true
    languageExtensions: {
      value: []
    }
    enablePurge: true
    enableDoubleEncryption: false
    engineType: 'V3'
    acceptedAudiences: []
    restrictOutboundNetworkAccess: 'Disabled'
    allowedFqdnList: []
    publicNetworkAccess: 'Enabled'
    allowedIpRangeList: []
    enableAutoStop: false
    publicIPType: 'IPv4'
  }
}

resource kustoDataStore 'Microsoft.Kusto/Clusters/Databases@2024-04-13' = {
  parent: kustoCluster
  name: '${dbwParams.kustoName}-data-store'
  location: location
  kind: 'ReadWrite'
  properties: {
    hotCachePeriod: 'P31D'
    softDeletePeriod: 'P365D'
  }
}

resource kustoDataStoreWatcherAdmin 'Microsoft.Kusto/Clusters/Databases/PrincipalAssignments@2024-04-13' = {
  parent: kustoDataStore
  name: 'bb83bb91-7227-53a0-8c2e-84c080085433'
  properties: {
    principalId: dbWatcher.identity.principalId
    role: 'Admin'
    principalType: 'App'
    tenantId: '770a2450-0227-4c62-90c7-4e38537f1102'
  }
}


// Azure has blocked changes to Database Watcher resources during retirement.
// Read the existing identity so the Kusto permissions can still be deployed.
resource dbWatcher 'Microsoft.DatabaseWatcher/watchers@2024-10-01-preview' existing = {
  name: dbwParams.name
}
