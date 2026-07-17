targetScope = 'resourceGroup'

param deploymentId string
param environment string
param location string
param tags object
param vnetParams object
param routeTableId string

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: vnetParams.name
  location: location
  tags: tags
  properties: {
    privateEndpointVNetPolicies: 'Disabled'
    addressSpace: {
      addressPrefixes: vnetParams.addressPrefixes
    }
    dhcpOptions: {
      dnsServers: vnetParams.dnsServers
    }
    subnets: [for subnet in vnetParams.subnets: {
      name: subnet.name
      properties: {
        addressPrefix: subnet.addressPrefix
        delegations: subnet.?delegations ?? []
        serviceEndpoints: subnet.?serviceEndpoints ?? []
        privateEndpointNetworkPolicies: subnet.?privateEndpointNetworkPolicies ?? 'Disabled'
        privateLinkServiceNetworkPolicies: subnet.?privateLinkServiceNetworkPolicies ?? 'Enabled'
        routeTable: {
          id: subnet.?routeTableId ?? routeTableId
        }
        networkSecurityGroup: {
          id: subnet.networkSecurityGroupId
        }
      }
    }]
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

output subnetIds array = [for subnet in vnetParams.subnets: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetParams.name, subnet.name)]
output subnets array = virtualNetwork.properties.subnets
output vnetName string = virtualNetwork.name
output vnetResourceId string = virtualNetwork.id

