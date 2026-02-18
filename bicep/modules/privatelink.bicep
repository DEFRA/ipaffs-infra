targetScope = 'resourceGroup'

param deploymentId string
param location string
param loadBalancerFrontendIpConfigurations array
param privateLinkParams object
param subnetNames object
param subnets array
param tags object

var subnet = first(filter(subnets, subnet => subnet.name == subnetNames.privateLink))

resource privateLink 'Microsoft.Network/privateLinkServices@2025-05-01' = {
  name: privateLinkParams.name
  location: location
  tags: tags

  properties: {
    enableProxyProtocol: false
    ipConfigurations: [
      {
        name: subnet.name
        properties: {
          primary: true
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: subnet.id
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
