targetScope = 'resourceGroup'

param deploymentId string
param newVnetResourceId string
param vnetParams object

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetParams.name
}

resource newPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-05-01' = {
  name: format('{0}-{1}', vnet.name, last(split(newVnetResourceId, '/')))
  parent: vnet
  properties: {
    allowForwardedTraffic: false
    allowGatewayTransit: false
    allowVirtualNetworkAccess: true
    enableOnlyIPv6Peering: false
    remoteVirtualNetwork: {
      id: newVnetResourceId
    }
  }
}

// vim: set ts=2 sts=2 sw=2 et:
