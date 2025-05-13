param bastionVnetName string
param remoteVnetId string

resource bastionVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: bastionVnetName
}

resource bastionToAks 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  name: 'bastion-to-aks'
  parent: bastionVnet
  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}
