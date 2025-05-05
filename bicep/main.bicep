param dnsPrefix string
param linuxAdminUsername string
@secure()
param sshRSAPublicKey string
param location string = resourceGroup().location
param aksResourceGroupName string = 'POCIMPINFRGP001'

module network 'network.bicep' = {
  name: 'deployNetwork'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    location: location
  }
}

module aks 'aks-cluster.bicep' = {
  name: 'deployAksCluster'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    dnsPrefix: dnsPrefix
    linuxAdminUsername: linuxAdminUsername
    sshRSAPublicKey: sshRSAPublicKey
    subnetId: network.outputs.subnetId
    location: location
  }
}
