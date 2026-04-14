targetScope = 'resourceGroup'

@allowed(['DEV', 'TST'])
param environment string

param subnets object = {}

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param privateLinkParams object

resource loadBalancer 'Microsoft.Network/loadBalancers@2025-05-01' existing = {
  name: privateLinkParams.loadBalancer.name
  scope: resourceGroup(privateLinkParams.loadBalancer.resourceGroup)
}

module privateLink './modules/privatelink.bicep' = {
  name: 'privateLink-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    loadBalancerFrontendIpConfigurations: loadBalancer.properties.frontendIPConfigurations
    location: location
    privateLinkParams: privateLinkParams
    subnets: subnets
    tags: tags
  }
}

// vim: set ts=2 sts=2 sw=2 et:
