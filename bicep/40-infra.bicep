targetScope = 'resourceGroup'

@allowed(['DEV', 'TST'])
param environment string

param acrName string
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

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: acrName
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetName
}

module acrPrivateEndpoint './modules/acr-private-endpoint.bicep' = {
  name: 'acr-${deploymentId}'
  scope: resourceGroup()
  params: {
    acrName: acrName
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
    acrName: acrName
    aksParams: aksParams
    deploymentId: deploymentId
    entraGroups: entraGroups
    location: location
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
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
    sqlServerName: sql.outputs.sqlServerName
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
    deploymentId: deploymentId
    entraGroups: entraGroups
    location: location
    storageParams: storageParams
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
    tags: tags
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output aksClusterName string = aks.outputs.aksClusterName
output aksOidcIssuer string = aks.outputs.oidcIssuerUrl
output azureServiceOperatorClientId string = aso.outputs.clientId
output externalSecretsClientId string = externalSecrets.outputs.clientId
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
