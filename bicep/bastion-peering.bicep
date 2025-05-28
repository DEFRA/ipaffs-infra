param aksVnetId string
param bastionVnetName string = 'bastion-vnet'

resource bastionVnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: bastionVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2022-07-01' = {
  name: 'bastion-to-aks'
  parent: bastionVnet
  properties: {
    remoteVirtualNetwork: {
      id: aksVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
  }
}
