targetScope = 'resourceGroup'

param deploymentId string
param location string
param tags object
param vnetParams object

module routeTable 'br/SharedDefraRegistry:network.route-table:0.4.2' = {
  name: 'route-table-aks-${deploymentId}'
  params: {
    name: '${vnetParams.routeTable.name}'
    location: location
    lock: ''
    tags: tags
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'Default'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: vnetParams.routeTable.virtualApplianceIp
        }
      }
    ]
  }
}

module virtualNetwork 'br/SharedDefraRegistry:network.virtual-network:0.4.2' = {
  name: 'virtual-network-${deploymentId}'
  params: {
    name: vnetParams.name
    location: location
    lock: ''
    tags: tags
    enableDefaultTelemetry: true
    addressPrefixes: vnetParams.addressPrefixes
    dnsServers: vnetParams.dnsServers
    subnets: vnetParams.subnets
  }
}

var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')

module vnetNetworkContributor './vnet-role-assignment.bicep' = [for principalId in vnetParams.principalsNeedingContributor: {
  name: format('vnetNetworkContributor-{0}-{1}', deploymentId, substring(uniqueString(principalId), 0, 7))
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    principalObjectId: principalId
    roleDefinitionId: networkContributorRoleId
    vnetName: vnetParams.name
  }
  dependsOn: [virtualNetwork]
}]

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetParams.name
  dependsOn: [virtualNetwork]
}

resource classicPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-05-01' = {
  name: format('{0}-{1}', vnet.name, last(split(vnetParams.classicVnetResourceId, '/')))
  parent: vnet
  properties: {
    allowForwardedTraffic: false
    allowGatewayTransit: false
    allowVirtualNetworkAccess: true
    enableOnlyIPv6Peering: false
    remoteVirtualNetwork: {
      id: vnetParams.classicVnetResourceId
    }
  }
}

output subnetIds array = virtualNetwork.outputs.subnetResourceIds
output subnets array = vnet.properties.subnets
output vnetName string = virtualNetwork.outputs.name
output vnetResourceId string = virtualNetwork.outputs.resourceId

// vim: set ts=2 sts=2 sw=2 et:
