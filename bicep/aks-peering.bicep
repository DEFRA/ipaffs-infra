param bastionVnetId string
param aksVnetName string = 'ipaffs-vnet'

resource aksVnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: aksVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2022-07-01' = {
  name: 'aks-to-bastion'
  parent: aksVnet
  properties: {
    remoteVirtualNetwork: {
      id: bastionVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
  }
}
