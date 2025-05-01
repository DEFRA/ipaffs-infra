param location string = resourceGroup().location
param clusterName string
param dnsPrefix string
param agentCount int = 3
param agentVMSize string = 'Standard_DS2_v2'

resource aks 'Microsoft.ContainerService/managedClusters@2025-04-06' = {
  name: clusterName
  location: location
  properties: {
    dnsPrefix: dnsPrefix
    agentPoolProfiles: [
      {
        name: 'agentpool'
        count: agentCount
        vmSize: agentVMSize
        mode: 'System'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
    identity: {
      type: 'SystemAssigned'
    }
    kubernetesVersion: ''
    enableRBAC: true
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
  }
}
