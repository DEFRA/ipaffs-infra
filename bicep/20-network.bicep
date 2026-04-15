targetScope = 'resourceGroup'

@allowed(['DEV', 'TST', 'PRE', 'PRD'])
param environment string

param subnetNames object

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param nsgParams object
param vnetParams object

module nsg './modules/network-security-groups.bicep' = {
  name: 'nsg-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    tags: tags
    nsgParams: nsgParams
  }
}

module vnet './modules/virtual-network.bicep' = {
  name: 'vnet-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    tags: tags
    vnetParams: vnetParams
  }
  dependsOn: [
    nsg
  ]
}

output aksApiServerSubnetId string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.aksApiServer)).id
output aksApiServerSubnetName string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.aksApiServer)).name
output aksSystemNodesSubnetId string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.aksSystemNodes)).id
output aksSystemNodesSubnetName string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.aksSystemNodes)).name
output aksUserNodesSubnetId string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.aksUserNodes)).id
output aksUserNodesSubnetName string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.aksUserNodes)).name
output appGatewayForContainersSubnetId string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.appGatewayForContainers)).id
output appGatewayForContainersSubnetName string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.appGatewayForContainers)).name
output privateEndpointsSubnetId string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.privateEndpoints)).id
output privateEndpointsSubnetName string = first(filter(vnet.outputs.subnets, subnet => subnet.name == subnetNames.privateEndpoints)).name
output vnetName string = vnet.outputs.vnetName

// vim: set ts=2 sts=2 sw=2 et:
