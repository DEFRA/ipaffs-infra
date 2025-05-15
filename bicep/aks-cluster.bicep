param dnsPrefix string
param linuxAdminUsername string
@secure()
param sshPublicKey string
param subnetId string
param location string
param acrName string
param clusterName string

resource aks 'Microsoft.ContainerService/managedClusters@2023-01-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: '1.32'

    agentPoolProfiles: [
      // System node pool
      {
//        name: 'POCIMPINFAK1401-systempool'
        name: 'ak1401sysnp'
        vmSize: 'Standard_E16as_v6'
//        vmSize: 'Standard_B2s'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        mode: 'System'
        vnetSubnetID: subnetId
        enableNodePublicIP: false
        minCount: 1
        maxCount: 3
//        maxCount: 1
        enableAutoScaling: true
      }

      // User/worker node pool
      {
//        name: 'POCIMPINFAK1401-userpool'
        name: 'ak1401usernp'
        vmSize: 'Standard_E16as_v6'
//        vmSize: 'Standard_B2s'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        mode: 'User'
        vnetSubnetID: subnetId
        enableNodePublicIP: false
        minCount: 1
        maxCount: 3
//        maxCount: 1
        enableAutoScaling: true
      }
    ]

    linuxProfile: {
      adminUsername: linuxAdminUsername
      ssh: {
        publicKeys: [
          {
            keyData: sshPublicKey
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
      enablePrivateCluster: false
    }

    addonProfiles: {}
  }
}
/* // unable to create role assignment
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' existing = {
  name: acrName
}
resource acrRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(aks.name, acr.name, 'acrpull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
    principalId: aks.identity.principalId
  }
}
*/