targetScope = 'resourceGroup'

@allowed(['DEV', 'TST', 'PRE', 'PRD'])
param environment string

param builtInGroups object
param classicLocation string
param classicResourceIds object
param entraGroups object
param subnets object
param tenantId string
param deployServicePrincipalObjectId string
param vnetName string

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param agcParams object
param aksParams object
param alertsParams object
param asoParams object
param externalSecretsParams object
param keyVaultParams object
param monitoringParams object
param qaKeyVaultParams object = {}
param qaAutomationPrincipalObjectId string = ''
param redisParams object
param searchParams object
param sqlParams object
param insightsParams object
param storageParams object

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetName
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

module agc './modules/application-gateway-for-containers.bicep' = {
  name: 'agc-${deploymentId}'
  scope: resourceGroup()
  params: {
    agcParams: agcParams
    aksNodeResourceGroupName: aksParams.nodeResourceGroup
    deploymentId: deploymentId
    location: location
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    subnetName: subnets.appGatewayForContainers.name
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

var keyVaultAdministratorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')
var keyVaultSecretsOfficerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

module keyVault './modules/keyvault.bicep' = {
  name: 'keyVault-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    keyVaultParams: keyVaultParams
    location: location
    subnets: subnets
    tags: tags
    tenantId: tenantId
    roleAssignments: [
      {
        principalObjectId: entraGroups.keyVaultAdmins.id
        principalType: 'Group'
        roleDefinitionId: keyVaultAdministratorRoleId
      }
      {
        principalObjectId: entraGroups.keyVaultSecretsReaders.id
        principalType: 'Group'
        roleDefinitionId: keyVaultSecretsUserRoleId
      }
    ]
  }
}

// Only depployed when an environment supplies qaKeyVaultParams (currently just envs/tst/40-infra.bicepparam).
var deployQaKeyVault = !empty(qaKeyVaultParams)
var qaSecretsOfficerObjectId = contains(entraGroups, 'qaKeyVaultSecretsOfficers') ? entraGroups.qaKeyVaultSecretsOfficers.id : ''
var qaKeyVaultRoleAssignments = concat(
  empty(qaSecretsOfficerObjectId) ? [] : [
    {
      principalObjectId: qaSecretsOfficerObjectId
      principalType: 'Group'
      roleDefinitionId: keyVaultSecretsOfficerRoleId
    }
  ],
  empty(qaAutomationPrincipalObjectId) ? [] : [
    {
      principalObjectId: qaAutomationPrincipalObjectId
      principalType: 'ServicePrincipal'
      roleDefinitionId: keyVaultSecretsUserRoleId
    }
  ]
)

module qaKeyVault './modules/keyvault.bicep' = if (deployQaKeyVault) {
  name: 'qaKeyVault-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    keyVaultParams: qaKeyVaultParams
    location: location
    subnets: subnets
    tags: tags
    tenantId: tenantId
    roleAssignments: qaKeyVaultRoleAssignments
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
    entraGroups: entraGroups
    deployServicePrincipalObjectId: deployServicePrincipalObjectId
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
output albControllerClientId string = agc.outputs.controllerClientId
output appGatewayForContainersResourceId string = agc.outputs.agcResourceId
output appGatewayForContainersFrontendName string = agc.outputs.frontendName
output appGatewayForContainersFrontendFqdn string = agc.outputs.frontendFqdn
output azureServiceOperatorClientId string = aso.outputs.clientId
output externalSecretsClientId string = externalSecrets.outputs.clientId
output externalSecretsPrincipalObjectId string = externalSecrets.outputs.principalObjectId
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output qaKeyVaultName string = deployQaKeyVault ? qaKeyVault!.outputs.keyVaultName : ''
output qaKeyVaultUri string = deployQaKeyVault ? qaKeyVault!.outputs.keyVaultUri : ''
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
output grafanaManagedIdentityPrincipalId string = monitoring.outputs.grafanaManagedIdentityPrincipalId
output grafanaName string = monitoring.outputs.grafanaName
output prometheusName string = monitoring.outputs.prometheusName
