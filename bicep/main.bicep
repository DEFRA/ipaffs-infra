targetScope = 'resourceGroup'

@allowed(['POC', 'TST'])
param environment string

param tenantId string

param acrParams object
param aksParams object
param asoParams object
param keyVaultParams object
param nsgParams object
param sqlParams object
param vnetParams object

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

module acr './modules/acr.bicep' = {
  name: 'acr-${deploymentId}'
  scope: resourceGroup()
  params: {
    acrParams: acrParams
    deploymentId: deploymentId
    location: location
    subnetIds: vnet.outputs.subnetIds
    tags: tags
  }
  dependsOn: [
    nsg
  ]
}

module aks './modules/aks.bicep' = {
  name: 'aks-${deploymentId}'
  scope: resourceGroup()
  params: {
    acrName: acr.outputs.acrName
    aksParams: aksParams
    deploymentId: deploymentId
    location: location
    tags: tags
    vnetName: vnet.outputs.vnetName
  }
  dependsOn: [
    nsg
  ]
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

module keyVault './modules/keyvault.bicep' = {
  name: 'keyVault-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    keyVaultParams: keyVaultParams
    location: location
    subnetIds: vnet.outputs.subnetIds
    tags: tags
    tenantId: tenantId
  }
  dependsOn: [
    nsg
  ]
}

module nsg './modules/network-security-groups.bicep' = {
  name: 'nsg-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    tags: tags
    nsgParams: nsgParams
  }
  dependsOn: [
    vnet
  ]
}

module sql './modules/sql.bicep' = {
  name: 'sql-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    sqlParams: sqlParams
    subnetIds: vnet.outputs.subnetIds
    tags: tags
    tenantId: tenantId
  }
}

module vnet './modules/virtual-network.bicep' = {
  name: 'vnet-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    tags: tags
    vnetParams: vnetParams
  }
}

output acrLoginServer string = acr.outputs.acrLoginServer
output acrName string = acr.outputs.acrName
output aksClusterName string = aks.outputs.aksClusterName
output aksOidcIssuer string = aks.outputs.oidcIssuerUrl
output azureServiceOperatorClientId string = aso.outputs.clientId
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output sqlAdminGroupId string = sql.outputs.sqlAdminGroupId
output sqlServerName string = sql.outputs.sqlServerName

// vim: set ts=2 sts=2 sw=2 et:
