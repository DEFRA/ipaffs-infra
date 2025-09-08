param name string
param dnsPrefix string
param version string
param linuxAdminUsername string
@secure()
param sshRSAPublicKey string
param subnetId string
param location string = resourceGroup().location

resource aks 'Microsoft.ContainerService/managedClusters@2023-01-01' = {
  name: name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: version

    agentPoolProfiles: [
      // System node pool
      {
        name: '${name}-systempool'
        vmSize: 'Standard_E16as_v6'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        mode: 'System'
        vnetSubnetID: subnetId
        enableNodePublicIP: false
        minCount: 1
        maxCount: 3
        enableAutoScaling: true
      }

      // User/worker node pool
      {
        name: '${name}-userpool'
        vmSize: 'Standard_E16as_v6'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        mode: 'User'
        vnetSubnetID: subnetId
        enableNodePublicIP: false
        minCount: 1
        maxCount: 5
        enableAutoScaling: true
      }
    ]

    linuxProfile: {
      adminUsername: linuxAdminUsername
      ssh: {
        publicKeys: [
          {
            keyData: sshRSAPublicKey
          }
        ]
      }
    }

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
    }

    addonProfiles: {}
  }
}