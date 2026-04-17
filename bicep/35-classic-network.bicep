targetScope = 'resourceGroup'

@allowed(['SND', 'TST', 'PRE', 'PRD'])
param environment string

param newVnetResourceId string

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param vnetParams object

module vnet './modules/virtual-network-classic.bicep' = {
  name: 'vnet-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    newVnetResourceId: newVnetResourceId
    vnetParams: vnetParams
  }
}

// vim: set ts=2 sts=2 sw=2 et:
