targetScope = 'resourceGroup'

param acrParams object
param aksParams object
param asoParams object
param environment string
param location string
param nsgParams object
param sqlParams object
param vnetParams object

param createdDate string = utcNow('yyyy-MM-dd')
param tenantId string

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

module acr './modules/acr.bicep' = {
  name: 'acr'
  scope: resourceGroup()
  params: {
    acrParams: acrParams
    location: location
    subnetIds: vnet.outputs.subnetIds
    tags: tags
  }
  dependsOn: [
    nsg
  ]
}

module aks './modules/aks.bicep' = {
  name: 'aks'
  scope: resourceGroup()
  params: {
    acrName: acr.outputs.acrName
    aksParams: aksParams
    location: location
    tags: tags
    vnetName: vnet.outputs.vnetName
  }
  dependsOn: [
    nsg
  ]
}

module aso './modules/azure-service-operator.bicep' = {
  name: 'aso'
  scope: resourceGroup()
  params: {
    asoParams: asoParams
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    location: location
    tags: tags
  }
}

module nsg './modules/network-security-groups.bicep' = {
  name: 'nsg'
  scope: resourceGroup()
  params: {
    location: location
    tags: tags
    nsgParams: nsgParams
  }
  dependsOn: [
    vnet
  ]
}

module sql './modules/sql.bicep' = {
  name: 'sql'
  scope: resourceGroup()
  params: {
    location: location
    sqlParams: sqlParams
    subnetIds: vnet.outputs.subnetIds
    tags: tags
    tenantId: tenantId
  }
}

module vnet './modules/virtual-network.bicep' = {
  name: 'vnet'
  scope: resourceGroup()
  params: {
    location: location
    tags: tags
    vnetParams: vnetParams
  }
}

output acrLoginServer string = acr.outputs.acrLoginServer
output azureServiceOperatorClientId string = aso.outputs.clientId

// vim: set ts=2 sts=2 sw=2 et:
