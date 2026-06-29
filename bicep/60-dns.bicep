targetScope = 'resourceGroup'

@allowed(['DEV', 'TST', 'PRE', 'PRD'])
param environment string

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param dnsParams object
param loadBalancer object

resource ingressLoadBalancer 'Microsoft.Network/loadBalancers@2025-05-01' existing = {
  name: loadBalancer.name
  scope: resourceGroup(loadBalancer.subscriptionId, loadBalancer.resourceGroup)
}

module dns './modules/dns.bicep' = {
  name: 'dns-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    dnsParams: dnsParams
    loadBalancerFrontendIpConfigurations: ingressLoadBalancer.properties.frontendIPConfigurations
    tags: tags
  }
}

