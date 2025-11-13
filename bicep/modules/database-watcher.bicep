targetScope = 'resourceGroup'

param databaseNames array
param dbwParams object
param location string
param tags object

var sqlServerHostname = '${last(split(dbwParams.sqlServerResourceId, '/'))}${environment().suffixes.sqlServerHostname}'

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

resource kustoDataStoreGroupAdmin 'Microsoft.Kusto/Clusters/Databases/PrincipalAssignments@2024-04-13' = {
  parent: kustoDataStore
  name: dbwParams.adminEntraGroup
  properties: {
    principalId: dbwParams.adminEntraGroup
    role: 'Admin'
    principalType: 'Group'
    tenantId: '770a2450-0227-4c62-90c7-4e38537f1102'
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


// watchers@2025-01-02 is not available in northeurope
resource dbWatcher 'Microsoft.DatabaseWatcher/watchers@2024-10-01-preview' = {
  name: dbwParams.name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    datastore: {
      adxClusterResourceId: kustoCluster.id
      kustoClusterDisplayName: kustoCluster.name
      kustoClusterUri: kustoCluster.properties.uri
      kustoDataIngestionUri: kustoCluster.properties.dataIngestionUri
      kustoDatabaseName: kustoDataStore.name
      kustoManagementUrl: 'https://portal.azure.com/resource/subscriptions${kustoCluster.id}/overview'
      kustoOfferingType: 'adx'
    }
  }
}

resource dbWatcherPrivateEndpointSql 'Microsoft.DatabaseWatcher/watchers/sharedPrivateLinkResources@2024-10-01-preview' = {
  parent: dbWatcher
  name: dbwParams.name
  properties: {
    privateLinkResourceId: dbwParams.sqlServerResourceId
    groupId: 'sqlServer'
    requestMessage: 'please'
  }
}

resource dbWatcherPrivateEndpointKusto 'Microsoft.DatabaseWatcher/watchers/sharedPrivateLinkResources@2024-10-01-preview' = {
  parent: dbWatcher
  name: '${dbwParams.name}-kusto'
  properties: {
    privateLinkResourceId: kustoCluster.id
    groupId: 'cluster'
    requestMessage: 'please'
    dnsZone: location
  }
}

resource dbWatcherTargetSqlEp 'Microsoft.DatabaseWatcher/watchers/targets@2024-10-01-preview' = {
  parent: dbWatcher
  name: dbwParams.sqlServerElasticPoolName
  properties: {
    targetAuthenticationType: 'Aad'
    connectionServerName: sqlServerHostname
    targetType: 'SqlEp'
    sqlEpResourceId: '${dbwParams.sqlServerResourceId}/elasticpools/${dbwParams.sqlServerElasticPoolName}'
    anchorDatabaseResourceId: '${dbwParams.sqlServerResourceId}/databases/${first(databaseNames)}'
    readIntent: false
  }
}

resource dbWatcherTargetSqlDb 'Microsoft.DatabaseWatcher/watchers/targets@2024-10-01-preview' = [for db in databaseNames: {
  parent: dbWatcher
  name: '${dbwParams.sqlServerElasticPoolName}-${db}'
  properties: {
    targetAuthenticationType: 'Aad'
    connectionServerName: sqlServerHostname
    targetType: 'SqlDb'
    sqlDbResourceId: '${dbwParams.sqlServerResourceId}/databases/${db}'
    readIntent: false
  }
}]

// vim: set ts=2 sts=2 sw=2 et:
