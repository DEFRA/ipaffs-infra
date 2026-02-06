targetScope = 'resourceGroup'

@allowed(['DEV', 'TST'])
param environment string

param builtInGroups object
param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location
param tenantId string

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param nsgParams object
param vnetParams object

module nsg './modules/network-security-groups.bicep' = {
  name: 'nsg-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    tags: tags
    nsgParams: nsgParams
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
  dependsOn: [
    nsg
  ]
}

// vim: set ts=2 sts=2 sw=2 et:
