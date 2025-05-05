param dnsPrefix string
param linuxAdminUsername string
@secure()
param sshRSAPublicKey string
param subnetId string
param location string = resourceGroup().location

resource aks 'Microsoft.ContainerService/managedClusters@2023-01-01' = {
  name: 'pocimpinfaks001'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: '1.32'

    agentPoolProfiles: [
      {
        name: 'agentpool'
        count: 2
        vmSize: 'Standard_DS2_v2'
        osType: 'Linux'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: subnetId
        enableNodePublicIP: false
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