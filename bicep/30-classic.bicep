targetScope = 'resourceGroup'

@allowed(['SND', 'TST', 'PRE', 'PRD'])
param environment string

param entraGroups object
param newVnetResourceId string

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location
param principalsNeedingContributor array
param tenantId string

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

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param alertsParams object
param dbwParams object
param redisParams object
param searchParams object
param sejParams object
param sqlParams object
param serviceBusParams object
param vnetParams object

var contributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

module additionalContributors './modules/resource-group-role-assignment.bicep' = [for principalId in principalsNeedingContributor: {
  name: format('additionalContributors-{0}-{1}', deploymentId, substring(uniqueString(principalId), 0, 7))
  params: {
    deploymentId: deploymentId
    principalObjectId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributorRoleId
  }
}]

// TODO: move this to infra module and lift to new subscription
module alerts './modules/alerts.bicep' = {
  name: 'alerts-${deploymentId}'
  scope: resourceGroup()
  params: {
    alertsParams: alertsParams
    deploymentId: deploymentId
    location: location
    tags: tags
  }
}

// TODO: move this to infra module and lift to new subscription
module dbw './modules/database-watcher.bicep' = {
  name: 'dbw-${deploymentId}'
  scope: resourceGroup()
  params: {
    databaseNames: databaseNames
    deploymentId: deploymentId
    location: location
    dbwParams: dbwParams
    tags: tags
  }
}

module redis './modules/redis-classic.bicep' = {
  name: 'redis-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    redisParams: redisParams
    tags: tags
  }
}

module search './modules/search-classic.bicep' = {
  name: 'search-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    entraGroups: entraGroups
    location: location
    searchParams: searchParams
    sqlServerName: sql.outputs.sqlServerName
    tags: tags
  }
}

// TODO: move this to infra module and lift to new subscription
module sej './modules/sql-elastic-jobs.bicep' = {
  name: 'sej-${deploymentId}'
  scope: resourceGroup()
  params: {
    alertsActionGroups: alerts.outputs.actionGroups
    deploymentId: deploymentId
    location: location
    sejParams: sejParams
    tags: tags
  }
}

module serviceBus './modules/servicebus-classic.bicep' = {
  name: 'serviceBus-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    serviceBusParams: serviceBusParams
    tags: tags
  }
}

module sql './modules/sql-classic.bicep' = {
  name: 'sql-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    entraGroups: entraGroups
    location: location
    sqlParams: sqlParams
    tags: tags
    tenantId: tenantId
  }
}

module vnet './modules/virtual-network-classic.bicep' = {
  name: 'vnet-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    newVnetResourceId: newVnetResourceId
    vnetParams: vnetParams
  }
}

output redisName string = redis.outputs.redisName
output redisResourceId string = redis.outputs.redisResourceId
output searchServiceSubscriptionId string = search.outputs.searchServiceSubscriptionId
output searchServiceResourceGroupName string = search.outputs.searchServiceResourceGroupName
output searchServiceName string = search.outputs.searchServiceName
output searchServiceManagedIdentityPrincipalName string = search.outputs.searchServiceManagedIdentityPrincipalName
output searchServiceManagedIdentityPrincipalId string = search.outputs.searchServiceManagedIdentityPrincipalId
output searchServiceResourceId string = search.outputs.searchServiceResourceId
output serviceBusNamespaceName string = serviceBus.outputs.serviceBusNamespaceName
output serviceBusNamespaceResourceId string = serviceBus.outputs.serviceBusNamespaceResourceId
output sqlServerName string = sql.outputs.sqlServerName
output sqlServerResourceId string = sql.outputs.sqlServerResourceId

// vim: set ts=2 sts=2 sw=2 et:
