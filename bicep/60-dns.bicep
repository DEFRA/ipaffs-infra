targetScope = 'resourceGroup'

param deploymentId string = uniqueString(utcNow())

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
    dnsParams: dnsParams
    loadBalancerFrontendIpConfigurations: ingressLoadBalancer.properties.frontendIPConfigurations
  }
}

