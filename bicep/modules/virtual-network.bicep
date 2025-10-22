targetScope = 'resourceGroup'

param location string
param tags object
param vnetParams object

param deploymentDate string = utcNow('yyyyMMdd-HHmmss')

module routeTable 'br/SharedDefraRegistry:network.route-table:0.4.2' = {
  name: 'route-table-aks-${deploymentDate}'
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
  name: 'virtual-network-${deploymentDate}'
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

output vnetName string = virtualNetwork.name

// vim: set ts=2 sts=2 sw=2 et:
