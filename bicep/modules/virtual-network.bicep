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

output vnetName string = virtualNetwork.outputs.name
output vnetId string = virtualNetwork.outputs.resourceId
output subnetIds array = virtualNetwork.outputs.subnetResourceIds

// vim: set ts=2 sts=2 sw=2 et:
