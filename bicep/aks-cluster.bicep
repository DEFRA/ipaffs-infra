param location string
param aksCluster object

resource aks 'Microsoft.ContainerService/managedClusters@2023-01-01' = {
  name: aksCluster.name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: aksCluster.dnsPrefix
    kubernetesVersion: aksCluster.version

    aadProfile: {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: aksCluster.adminGroupObjectIDs
    }

    agentPoolProfiles: [
      // System node pool
      {
        name: 'system'
        vmSize: 'Standard_E16as_v6'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        mode: 'System'
        vnetSubnetID: aksCluster.subnetId
        enableNodePublicIP: false
        minCount: 1
        maxCount: 3
        enableAutoScaling: true
      }

      // User/worker node pool
      {
        name: 'user'
        vmSize: 'Standard_E16as_v6'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        mode: 'User'
        vnetSubnetID: aksCluster.subnetId
        enableNodePublicIP: false
        minCount: 1
        maxCount: 5
        enableAutoScaling: true
      }
    ]

    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'calico'
      loadBalancerSku: 'standard'
      outboundType: 'userDefinedRouting'
      serviceCidr: '10.240.0.0/16'
      dnsServiceIP: '10.240.0.10'
      dockerBridgeCidr: '172.17.0.1/16'
    }

    apiServerAccessProfile: {
      enablePrivateCluster: true
      privateDNSZone: 'none'
    }

    addonProfiles: {}
  }
}