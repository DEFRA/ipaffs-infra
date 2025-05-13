param aksVnetName string
param remoteVnetId string

resource aksVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: aksVnetName
}

resource aksToBastion 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  name: 'aks-to-bastion'
  parent: aksVnet
  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}
