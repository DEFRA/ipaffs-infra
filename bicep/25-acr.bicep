targetScope = 'resourceGroup'

@allowed(['DEV'])
param environment string

param subnetNames object
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

// vim: set ts=2 sts=2 sw=2 et:
