targetScope = 'resourceGroup'

param acrName string
param aksParams object
param deploymentId string
param location string
param tags object
param vnetName string
param logAnalyticsId string

resource aksCluster 'Microsoft.ContainerService/managedClusters@2025-07-01' = {
  name: aksParams.name
  location: location
  tags: tags

  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    dnsPrefix: aksParams.dnsPrefix
    kubernetesVersion: aksParams.version

    aadProfile: {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: aksParams.adminGroupObjectIDs
    }

    agentPoolProfiles: [
      {
        name: 'system'
        vmSize: 'Standard_E16as_v6' // TODO: change to 'Standard_E2as_v6'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        mode: 'System'
        vnetSubnetID: aksParams.subnetId
        enableNodePublicIP: false
        minCount: 2
        maxCount: 3
        enableAutoScaling: true
      }
      {
        name: 'user'
        vmSize: 'Standard_E16as_v6'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        mode: 'User'
        vnetSubnetID: aksParams.subnetId
        enableNodePublicIP: false
        minCount: 2
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
    }

    apiServerAccessProfile: {
      enablePrivateCluster: true
      privateDNSZone: 'none'
    }

    oidcIssuerProfile: {
      enabled: true
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

    azureMonitorProfile: {
      metrics: {
        enabled: true
        kubeStateMetrics: {
          metricAnnotationsAllowList: '*'
          metricLabelsAllowlist: '*'
        }
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
