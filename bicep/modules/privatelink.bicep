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
    accessMode: 'Default'
    enableProxyProtocol: false
    ipConfigurations: [
      {
        id: resourceId('Microsoft.Network/privateLinkServices/ipConfigurations', privateLinkParams.name, subnets.privateEndpoints.name)
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

