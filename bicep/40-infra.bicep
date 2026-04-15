targetScope = 'resourceGroup'

@allowed(['DEV', 'TST', 'PRE', 'PRD'])
param environment string

param acrResourceId string
param builtInGroups object
param classicLocation string
param classicResourceIds object
param entraGroups object
param subnets object
param tenantId string
param vnetName string

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param aksParams object
param alertsParams object
param asoParams object
param externalSecretsParams object
param keyVaultParams object
param monitoringParams object
param redisParams object
param searchParams object
param sqlParams object
param insightsParams object
param storageParams object

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetName
}

module acrPrivateEndpoint './modules/acr-private-endpoint.bicep' = {
  name: 'acrPrivateEndpoint-${deploymentId}'
  scope: resourceGroup()
  params: {
    acrResourceId: acrResourceId
    deploymentId: deploymentId
    location: location
    subnets: subnets
    tags: tags
  }
}

module aks './modules/aks.bicep' = {
  name: 'aks-${deploymentId}'
  scope: resourceGroup()
  params: {
    aksParams: aksParams
    deploymentId: deploymentId
    entraGroups: entraGroups
    location: location
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    subnets: subnets
    tags: tags
    vnetName: vnetName
  }
}

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

module aso './modules/azure-service-operator.bicep' = {
  name: 'aso-${deploymentId}'
  scope: resourceGroup()
  params: {
    asoParams: asoParams
    deploymentId: deploymentId
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    location: location
    tags: tags
  }
}

module classicPrivateEndpoints './modules/classic-private-endpoints.bicep' = {
  name: 'classicPrivateEndpoints-${deploymentId}'
  scope: resourceGroup()
  params: {
    classicResourceIds: classicResourceIds
    deploymentId: deploymentId
    location: location
    subnets: subnets
    tags: tags
  }
}

module externalSecrets './modules/external-secrets-identity.bicep' = {
  name: 'externalSecrets-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    externalSecretsParams: externalSecretsParams
    keyVaultName: keyVault.outputs.keyVaultName
    location: location
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    tags: tags
  }
}

module keyVault './modules/keyvault.bicep' = {
  name: 'keyVault-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    entraGroups: entraGroups
    keyVaultParams: keyVaultParams
    location: location
    subnets: subnets
    tags: tags
    tenantId: tenantId
  }
}

module redis './modules/redis.bicep' = {
  name: 'redis-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    redisParams: redisParams
    location: location
    subnets: subnets
    tags: tags
    tenantId: tenantId
  }
}

module search './modules/search.bicep' = {
  name: 'search-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    entraGroups: entraGroups
    searchParams: searchParams
    location: location
    sqlServerName: sql.outputs.sqlServerName
    subnets: subnets
    tags: tags
    tenantId: tenantId
  }
}

module sql './modules/sql.bicep' = {
  name: 'sql-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    entraGroups: entraGroups
    location: location
    sqlParams: sqlParams
    subnets: subnets
    tags: tags
    tenantId: tenantId
  }
}

module monitoring './modules/monitoring.bicep' = {
  name: 'monitoring-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    tags: tags
    monitoringParams: monitoringParams
  }
}

module insights './modules/insights.bicep' = {
  name: 'insights-${deploymentId}'
  scope: resourceGroup()
  params: {
    insightsParams: insightsParams
    deploymentId: deploymentId
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    location: location
    tags: tags
  }
}

module storage './modules/storage.bicep' = {
  name: 'storage-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    entraGroups: entraGroups
    location: location
    storageParams: storageParams
    subnets: subnets
    tags: tags
  }
}

output aksClusterName string = aks.outputs.aksClusterName
output aksKubeletPrincipalId string = aks.outputs.kubeletPrincipalId
output aksOidcIssuer string = aks.outputs.oidcIssuerUrl
output azureServiceOperatorClientId string = aso.outputs.clientId
output externalSecretsClientId string = externalSecrets.outputs.clientId
output externalSecretsPrincipalObjectId string = externalSecrets.outputs.principalObjectId
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output redisName string = redis.outputs.redisName
output searchServiceSubscriptionId string = search.outputs.searchServiceSubscriptionId
output searchServiceResourceGroupName string = search.outputs.searchServiceResourceGroupName
output searchServiceName string = search.outputs.searchServiceName
output searchServiceManagedIdentityPrincipalName string = search.outputs.searchServiceManagedIdentityPrincipalName
output searchServiceManagedIdentityPrincipalId string = search.outputs.searchServiceManagedIdentityPrincipalId
output sqlServerName string = sql.outputs.sqlServerName
output sqlServerManagedIdentityObjectId string = sql.outputs.sqlServerManagedIdentityObjectId
output storageAccountName string = storage.outputs.storageAccountName
output insightsInstrumentationKey string = insights.outputs.insightsInstrumentationKey
output insightsConnectionString string = insights.outputs.insightsConnectionString

// vim: set ts=2 sts=2 sw=2 et:
