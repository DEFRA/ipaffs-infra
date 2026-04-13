targetScope = 'resourceGroup'

param deploymentId string
param location string
param loadBalancerFrontendIpConfigurations array
param privateLinkParams object
param subnets object
param tags object

resource privateLink 'Microsoft.Network/privateLinkServices@2025-05-01' = {
  name: privateLinkParams.name
  location: location
  tags: tags

  properties: {
    enableProxyProtocol: false
    ipConfigurations: [
      {
        name: subnets.privateEndpoints.name
        properties: {
          primary: true
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: subnets.privateEndpoints.id
          }
        }
      }
    ]
    loadBalancerFrontendIpConfigurations: [for config in loadBalancerFrontendIpConfigurations: {
      id: config.id
    }]
  }
}

// vim: set ts=2 sts=2 sw=2 et:
