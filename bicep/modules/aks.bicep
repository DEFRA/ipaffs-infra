targetScope = 'resourceGroup'

param acrName string
param aksParams object
param deploymentId string
param location string
param logAnalyticsId string
param subnetNames object
param subnets array
param tags object
param vnetName string

var apiServerSubnet = first(filter(subnets, subnet => subnet.name == subnetNames.aksApiServer))
var systemNodePoolSubnet = first(filter(subnets, subnet => subnet.name == subnetNames.aksSystemNodes))
var userNodePoolSubnet = first(filter(subnets, subnet => subnet.name == subnetNames.aksUserNodes))

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: aksParams.userAssignedIdentityName
  location: location
  tags: tags
}

var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')

module vnetNetworkContributor './vnet-role-assignment.bicep' = {
  name: 'vnetNetworkContributor-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    principalObjectId: userAssignedIdentity.properties.principalId
    roleDefinitionId: networkContributorRoleId
    vnetName: vnetName
  }
}

resource aksCluster 'Microsoft.ContainerService/managedClusters@2025-10-01' = {
  name: aksParams.name
  location: location
  tags: tags

  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }

  properties: {
    dnsPrefix: aksParams.dnsPrefix
    kubernetesVersion: aksParams.version
    nodeResourceGroup: aksParams.nodeResourceGroup
    publicNetworkAccess: 'Disabled'

    aadProfile: {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: aksParams.adminGroupObjectIDs
    }

    addonProfiles: {
      omsAgent: {
        enabled: true
        config: {
          useAADAuth: 'true'
          logAnalyticsWorkspaceResourceID: logAnalyticsId
        }
      }
    }

    agentPoolProfiles: [
      {
        name: 'system'
        enableAutoScaling: true
        enableNodePublicIP: false
        minCount: aksParams.nodePools.system.minCount
        maxCount: aksParams.nodePools.system.maxCount
        maxPods: aksParams.nodePools.system.maxPods
        mode: 'System'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vmSize: aksParams.nodePools.system.vmSize
        vnetSubnetID: systemNodePoolSubnet.id

        securityProfile: {
          enableSecureBoot: true
          enableVTPM: true
        }
      }
      {
        name: 'user'
        enableAutoScaling: true
        enableNodePublicIP: false
        minCount: aksParams.nodePools.user.minCount
        maxCount: aksParams.nodePools.user.maxCount
        maxPods: aksParams.nodePools.user.maxPods
        mode: 'User'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vmSize: aksParams.nodePools.user.vmSize
        vnetSubnetID: userNodePoolSubnet.id

        securityProfile: {
          enableSecureBoot: true
          enableVTPM: true
        }
      }
    ]

    apiServerAccessProfile: {
      enablePrivateCluster: true
      enableVnetIntegration: true
      privateDNSZone: 'none'
      subnetId: apiServerSubnet.id
    }

    autoUpgradeProfile: {
      nodeOSUpgradeChannel: 'SecurityPatch'
      upgradeChannel: 'none'
    }

    azureMonitorProfile: {
      metrics: {
        enabled: true
        kubeStateMetrics: {
          metricAnnotationsAllowList: '*'
          metricLabelsAllowlist: '*'
        }
      }
    }

    // See https://learn.microsoft.com/en-us/azure/aks/app-routing-nginx-configuration?pivots=nginx-ingress-controller
    ingressProfile: {
      webAppRouting: {
        enabled: true
        nginx: {
          defaultIngressControllerType: 'None'
        }
      }
    }

    networkProfile: {
      dnsServiceIP: aksParams.dnsServiceIp
      ipFamilies: ['IPv4']
      loadBalancerSku: 'standard'
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'calico'
      outboundType: 'userDefinedRouting'
      podCidrs: aksParams.podCidrs
      serviceCidrs: aksParams.serviceCidrs
    }

    oidcIssuerProfile: {
      enabled: true
    }

    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
  }

  sku: {
    name: 'Base'
    tier: aksParams.sku
  }
}

var aksRbacClusterAdminRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
var aksRbacWriterRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a7ffa36f-339b-4b5c-8bdf-e2c188b2c0eb')
var aksRbacReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f6c6a51-bcf8-42ba-9220-52d62157d7db')

module aksAdmin './aks-role-assignment.bicep' = {
  name: 'aksAdmin-${deploymentId}'
  scope: resourceGroup()
  params: {
    aksName: aksParams.name
    deploymentId: deploymentId
    principalObjectId: entraGroups.aksAdmins.id
    principalType: 'Group'
    roleDefinitionId: aksRbacClusterAdminRoleId
  }
}

module aksWriter './aks-role-assignment.bicep' = {
  name: 'aksWriter-${deploymentId}'
  scope: resourceGroup()
  params: {
    aksName: aksParams.name
    deploymentId: deploymentId
    principalObjectId: entraGroups.aksContributors.id
    principalType: 'Group'
    roleDefinitionId: aksRbacWriterRoleId
  }
}

module aksReader './aks-role-assignment.bicep' = {
  name: 'aksReader-${deploymentId}'
  scope: resourceGroup()
  params: {
    aksName: aksParams.name
    deploymentId: deploymentId
    principalObjectId: entraGroups.aksReaders.id
    principalType: 'Group'
    roleDefinitionId: aksRbacReaderRoleId
  }
}

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

module acrPull './acr-role-assignment.bicep' = {
  name: 'acrPull-${deploymentId}'
  scope: resourceGroup()
  params: {
    acrName: acrName
    deploymentId: deploymentId
    principalObjectId: aksCluster.properties.identityProfile.kubeletIdentity.objectId
    roleDefinitionId: acrPullRoleId
  }
}

output aksClusterName string = aksCluster.name
output kubeletPrincipalId string = aksCluster.properties.identityProfile.kubeletIdentity.objectId
output oidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL

// vim: set ts=2 sts=2 sw=2 et:
