param name string
param location string = resourceGroup().location
param adminEntraGroup string
param sqlServerElasticPoolName string
param sqlServerResourceId string = '/subscriptions/00f1225e-37c2-4c7b-bc71-634164b667c6/resourceGroups/TSTIMPINFRGP001/providers/Microsoft.Sql/servers/tstimpdbssqa001'
var sqlServerHostname = '${last(split(sqlServerResourceId, '/'))}${environment().suffixes.sqlServerHostname}'

var databaseNames = [
  'notification-microservice'
  'approvedestablishment-microservice-blue'
  'approvedestablishment-microservice-green'
  'bip-microservice'
  'bordernotification-microservice'
  'bordernotification-refdata-microservice-blue'
  'bordernotification-refdata-microservice-green'
  'checks-microservice'
  'commoditycode-microservice-blue'
  'commoditycode-microservice-green'
  'countries-microservice-blue'
  'countries-microservice-green'
  'decision-microservice-blue'
  'decision-microservice-green'
  'economicoperator-microservice'
  'economicoperator-microservice-public-blue'
  'economicoperator-microservice-public-green'
  'enotification-event-microservice'
  'fieldconfig-microservice-blue'
  'fieldconfig-microservice-green'
  'in-service-messaging-microservice'
  'laboratories-microservice-blue'
  'laboratories-microservice-green'
  'permissions-blue'
  'permissions-green'
  'referencedataloader-microservice-blue'
  'referencedataloader-microservice-green'
  'soaprequest-microservice'
]

resource kustoCluster 'Microsoft.Kusto/Clusters@2024-04-13' = {
  name: name
  location: location
  sku: {
    name: 'Standard_E2ads_v5'
    tier: 'Standard'
    capacity: 2
  }
  identity: {
    type: 'None'
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
  name: '${name}-data-store'
  location: location
  kind: 'ReadWrite'
  properties: {
    hotCachePeriod: 'P31D'
    softDeletePeriod: 'P365D'
  }
}

resource kustoDataStoreGroupAdmin 'Microsoft.Kusto/Clusters/Databases/PrincipalAssignments@2024-04-13' = {
  parent: kustoDataStore
  name: adminEntraGroup
  properties: {
    principalId: adminEntraGroup
    role: 'Admin'
    principalType: 'Group'
    tenantId: '770a2450-0227-4c62-90c7-4e38537f1102'
  }
}

resource kustoDataStoreWatcherAdmin 'Microsoft.Kusto/Clusters/Databases/PrincipalAssignments@2024-04-13' = {
  parent: kustoDataStore
  name: 'bb83bb91-7227-53a0-8c2e-84c080085433'
  properties: {
    principalId: '4503cc7e-addf-40d8-80a7-2faf08b77b71'
    role: 'Admin'
    principalType: 'App'
    tenantId: '770a2450-0227-4c62-90c7-4e38537f1102'
  }
}


resource dbWatcher 'Microsoft.DatabaseWatcher/watchers@2024-10-01-preview' = {
  name: name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    datastore: {
      adxClusterResourceId: kustoCluster.id
      kustoClusterDisplayName: 'tstimpdbsdbw001'
      kustoClusterUri: 'https://tstimpdbsdbw001.northeurope.kusto.windows.net'
      kustoDataIngestionUri: 'https://ingest-tstimpdbsdbw001.northeurope.kusto.windows.net'
      kustoDatabaseName: kustoDataStore.name
      kustoManagementUrl: 'https://portal.azure.com/resource/subscriptions${kustoCluster.id}/overview'
      kustoOfferingType: 'adx'
    }
  }
}

resource dbWatcherPrivateEndpointSql 'Microsoft.DatabaseWatcher/watchers/sharedPrivateLinkResources@2024-10-01-preview' = {
  parent: dbWatcher
  name: name
  properties: {
    privateLinkResourceId: sqlServerResourceId
    groupId: 'sqlServer'
    requestMessage: 'please'
  }
}

resource dbWatcherPrivateEndpointKusto 'Microsoft.DatabaseWatcher/watchers/sharedPrivateLinkResources@2024-10-01-preview' = {
  parent: dbWatcher
  name: '${name}-kusto'
  properties: {
    privateLinkResourceId: kustoCluster.id
    groupId: 'cluster'
    requestMessage: 'please'
    dnsZone: location
  }
}

resource dbWatcherTargetSqlEp 'Microsoft.DatabaseWatcher/watchers/targets@2024-10-01-preview' = {
  parent: dbWatcher
  name: sqlServerElasticPoolName
  properties: {
    targetAuthenticationType: 'Aad'
    connectionServerName: sqlServerHostname
    targetType: 'SqlEp'
    sqlEpResourceId: '${sqlServerResourceId}/elasticpools/${sqlServerElasticPoolName}'
    anchorDatabaseResourceId: '${sqlServerResourceId}/databases/${first(databaseNames)}'
    readIntent: false
  }
}

resource dbWatcherTargetSqlDb 'Microsoft.DatabaseWatcher/watchers/targets@2024-10-01-preview' = [for db in databaseNames: {
  parent: dbWatcher
  name: '${sqlServerElasticPoolName}-${db}'
  properties: {
    targetAuthenticationType: 'Aad'
    connectionServerName: sqlServerHostname
    targetType: 'SqlDb'
    sqlDbResourceId: '${sqlServerResourceId}/databases/${db}'
    readIntent: false
  }
}]

// vim: set ts=2 sts=2 sw=2 et:
