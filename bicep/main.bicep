/*param dnsPrefix string
param linuxAdminUsername string
@secure()
param sshRSAPublicKey string
*/
param location string = resourceGroup().location

param aksResourceGroupName string = 'POCIMPINFRG1401'
/*
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
*/
module acr 'acr.bicep' = {
  name: 'createAcr'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    name: 'POCIMPINFAC1401'
    location: location
    sku: 'Premium' // or 'Premium' if you need private endpoints
    adminEnabled: true
  }
}
