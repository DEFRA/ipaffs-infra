targetScope = 'resourceGroup'

@allowed(['DEV', 'TST'])
param environment string

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

param privateLinkParams object

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetName
}

module privateLink './modules/privatelink.bicep' = {
  name: 'privateLink-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    privateLinkParams: privateLinkParams
    subnetNames: subnetNames
    subnets: vnet.properties.subnets
    tags: tags
  }
}

// vim: set ts=2 sts=2 sw=2 et:
