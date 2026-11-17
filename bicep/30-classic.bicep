targetScope = 'resourceGroup'

@allowed(['SND', 'TST', 'PRE', 'PRD'])
param environment string

param entraGroups object

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location
param principalsNeedingContributor array
param tenantId string

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param alertsParams object
param dbwParams object?
param redisParams object?
param searchParams object?
param sejParams object?
param sqlParams object?
// Optional: the elastic pools to manage. An entry may set resourceGroupName when its
// pool is outside this resource group (PRE-TRN). SND manages none.
param sqlPoolsParams array = []
param serviceBusParams object

var contributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
var deployRedis = redisParams != null
var deploySearch = searchParams != null
var deployElasticJobs = sejParams != null
var deploySql = sqlParams != null

module additionalContributors './modules/resource-group-role-assignment.bicep' = [for principalId in principalsNeedingContributor: {
  name: format('additionalContributors-{0}-{1}', deploymentId, substring(uniqueString(principalId), 0, 7))
  params: {
    deploymentId: deploymentId
    principalObjectId: principalId
    principalType: 'ServicePrincipal'
    roleAssignmentType: 'permanent'
    roleDefinitionId: contributorRoleId
  }
}]

module alerts './modules/alerts-classic.bicep' = {
  name: 'alerts-${deploymentId}'
  scope: resourceGroup()
  params: {
    alertsParams: alertsParams
    tags: tags
  }
}

module dbw './modules/database-watcher.bicep' = if (dbwParams != null) {
  name: 'dbw-${deploymentId}'
  scope: resourceGroup()
  params: {
    location: location
    dbwParams: dbwParams!
    tags: tags
  }
}

module redis './modules/redis-classic.bicep' = if (deployRedis) {
  name: 'redis-${deploymentId}'
  scope: resourceGroup()
  params: {
    redisParams: redisParams!
  }
}

module search './modules/search-classic.bicep' = if (deploySearch) {
  name: 'search-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    searchParams: searchParams!
    sqlServerName: deploySql ? sql!.outputs.sqlServerName : ''
    tags: tags
  }
}

module sej './modules/sql-elastic-jobs.bicep' = if (deployElasticJobs) {
  name: 'sej-${deploymentId}'
  scope: resourceGroup()
  params: {
    // Calculate the ID without a deployment output so what-if can resolve it.
    alertsActionGroups: {
      notifyDba: resourceId('Microsoft.Insights/actionGroups', alertsParams.actionGroups.notifyDba.name)
    }
    location: location
    sejParams: sejParams!
    tags: tags
  }
  dependsOn: [alerts]
}

module serviceBus './modules/servicebus-classic.bicep' = {
  name: 'serviceBus-${deploymentId}'
  scope: resourceGroup()
  params: {
    serviceBusParams: serviceBusParams
  }
}

module sql './modules/sql-classic.bicep' = if (deploySql) {
  name: 'sql-${deploymentId}'
  scope: resourceGroup()
  params: {
    entraGroups: entraGroups
    sqlParams: sqlParams!
    tenantId: tenantId
  }
}

resource liveSqlPools 'Microsoft.Sql/servers/elasticPools@2023-08-01' existing = [for pool in sqlPoolsParams: if (pool.?keepLiveCapacity ?? false) {
  name: '${pool.serverName}/${pool.name}'
  scope: resourceGroup(pool.?resourceGroupName ?? resourceGroup().name)
}]

module sqlPools './modules/sql-pool-classic.bicep' = [for (pool, i) in sqlPoolsParams: {
  name: 'sqlPool-${pool.name}-${deploymentId}'
  scope: resourceGroup(pool.?resourceGroupName ?? resourceGroup().name)
  params: {
    livePerDatabaseSettings: (pool.?keepLiveCapacity ?? false) ? liveSqlPools[i]!.properties.perDatabaseSettings : {}
    liveSku: (pool.?keepLiveCapacity ?? false) ? liveSqlPools[i]!.sku : {}
    location: location
    sqlPoolParams: pool
  }
}]

output redisName string = deployRedis ? redis!.outputs.redisName : ''
output redisResourceId string = deployRedis ? redis!.outputs.redisResourceId : ''
output searchServiceSubscriptionId string = deploySearch ? search!.outputs.searchServiceSubscriptionId : ''
output searchServiceResourceGroupName string = deploySearch ? search!.outputs.searchServiceResourceGroupName : ''
output searchServiceName string = deploySearch ? search!.outputs.searchServiceName : ''
output searchServiceManagedIdentityPrincipalName string = deploySearch ? search!.outputs.searchServiceManagedIdentityPrincipalName : ''
output searchServiceManagedIdentityPrincipalId string = deploySearch ? search!.outputs.searchServiceManagedIdentityPrincipalId : ''
output searchServiceResourceId string = deploySearch ? search!.outputs.searchServiceResourceId : ''
output serviceBusNamespaceName string = serviceBus.outputs.serviceBusNamespaceName
output serviceBusNamespaceResourceId string = serviceBus.outputs.serviceBusNamespaceResourceId
output sqlServerName string = deploySql ? sql!.outputs.sqlServerName : ''
output sqlServerResourceId string = deploySql ? sql!.outputs.sqlServerResourceId : ''

