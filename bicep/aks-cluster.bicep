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

resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' existing = {
  name: 'POCIMPINFAC1401'
}

var acrPullRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
)

resource acrPullToKubelet 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acrPullRoleId, 'main')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: aks.properties.identityProfile['kubeletidentity'].objectId
    principalType: 'ServicePrincipal'
  }
}
  
var networkContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4d97b98b-1d4f-4787-a291-c67834d212e7' // Network Contributor
)

resource networkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acrPullRoleId, 'main')
  scope: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/virtualNetworks/POCIMPNETVN1401'
  properties: {
    roleDefinitionId: networkContributorRoleId
    principalId: aks.properties.identityProfile['kubeletidentity'].objectId
    principalType: 'ServicePrincipal'
  }
}


output kubeletObjectId string = aks.properties.identityProfile['kubeletidentity'].objectId