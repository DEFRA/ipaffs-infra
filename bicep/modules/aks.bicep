targetScope = 'resourceGroup'

param acrName string
param aksParams object
param deploymentId string
param location string
param logAnalyticsId string
param subnetIds array
param subnetNames object
param tags object
param vnetName string

var apiServerSubnetId = first(filter(subnetIds, subnetId => contains(subnetId, subnetNames.aksApiServer)))
var systemNodePoolSubnetId = first(filter(subnetIds, subnetId => contains(subnetId, subnetNames.aksSystemNodes)))
var userNodePoolSubnetId = first(filter(subnetIds, subnetId => contains(subnetId, subnetNames.aksUserNodes)))

resource aksCluster 'Microsoft.ContainerService/managedClusters@2025-10-01' = {
  name: aksParams.name
  location: location
  tags: tags

  identity: {
    type: 'SystemAssigned'
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
        maxCount: aksParams.nodePools.system.maxCount
        minCount: aksParams.nodePools.system.minCount
        mode: 'System'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vmSize: aksParams.nodePools.system.vmSize
        vnetSubnetID: systemNodePoolSubnetId

        securityProfile: {
          enableSecureBoot: true
          enableVTPM: true
        }
      }
      {
        name: 'user'
        enableAutoScaling: true
        enableNodePublicIP: false
        maxCount: aksParams.nodePools.user.maxCount
        minCount: aksParams.nodePools.user.minCount
        mode: 'User'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vmSize: aksParams.nodePools.user.vmSize
        vnetSubnetID: userNodePoolSubnetId

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
      subnetId: apiServerSubnetId
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

    oidcIssuerProfile: {
      enabled: true
    }

    networkProfile: {
      dnsServiceIP: '10.240.0.10'
      loadBalancerSku: 'standard'
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'calico'
      outboundType: 'userDefinedRouting'
      podCidr: '10.240.0.0/16'
      serviceCidr: '10.240.0.0/16'
    }

    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
  }
}



var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')

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

module vnetNetworkContributor './vnet-role-assignment.bicep' = {
  name: 'vnetNetworkContributor-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    principalObjectId: aksCluster.identity.principalId
    roleDefinitionId: networkContributorRoleId
    vnetName: vnetName
  }
}

output aksClusterName string = aksCluster.name
output kubeletPrincipalId string = aksCluster.properties.identityProfile.kubeletIdentity.objectId
output oidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL

// vim: set ts=2 sts=2 sw=2 et:
