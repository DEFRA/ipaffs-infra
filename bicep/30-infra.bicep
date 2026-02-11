targetScope = 'resourceGroup'

@allowed(['DEV', 'TST'])
param environment string

param builtInGroups object
param entraGroups object
param subnetNames object
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

param acrParams object
param aksParams object
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

module acr './modules/acr.bicep' = {
  name: 'acr-${deploymentId}'
  scope: resourceGroup()
  params: {
    acrParams: acrParams
    deploymentId: deploymentId
    location: location
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
    tags: tags
  }
}

module aks './modules/aks.bicep' = {
  name: 'aks-${deploymentId}'
  scope: resourceGroup()
  params: {
    acrName: acr.outputs.acrName
    aksParams: aksParams
    deploymentId: deploymentId
    location: location
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
    tags: tags
    vnetName: vnetName
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

module externalSecrets './modules/external-secrets-identity.bicep' = {
  name: 'externalSecrets-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    externalSecretsParams: externalSecretsParams
    location: location
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    tags: tags
  }
}

var keyVaultParamsWithManagedIdentities = union(keyVaultParams, {
  principalObjectIds: union(keyVaultParams.principalObjectIds, [
    externalSecrets.outputs.principalObjectId
  ])
})

module keyVault './modules/keyvault.bicep' = {
  name: 'keyVault-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    keyVaultParams: keyVaultParamsWithManagedIdentities
    location: location
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
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
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
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
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
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
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
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
    location: location
    storageParams: storageParams
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
    tags: tags
  }
}

output acrLoginServer string = acr.outputs.acrLoginServer
output acrName string = acr.outputs.acrName
output aksClusterName string = aks.outputs.aksClusterName
output aksOidcIssuer string = aks.outputs.oidcIssuerUrl
output azureServiceOperatorClientId string = aso.outputs.clientId
output externalSecretsClientId string = externalSecrets.outputs.clientId
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output redisName string = redis.outputs.redisName
output searchServiceName string = search.outputs.searchServiceName
output sqlServerName string = sql.outputs.sqlServerName
output sqlServerManagedIdentityObjectId string = sql.outputs.sqlServerManagedIdentityObjectId
output insightsInstrumentationKey string = insights.outputs.insightsInstrumentationKey // todo
output insightsConnectionString string = insights.outputs.insightsConnectionString // todo

// vim: set ts=2 sts=2 sw=2 et:
