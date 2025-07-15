@description('Required. The VNET Infra object.')
param vnet object

@description('Required. The subnets object.')
param subnets array

@allowed([
  'UKSouth'
])
@description('Required. The Azure region where the resources will be deployed.')
param location string
@description('Required. Environment name.')
param environment string
@description('Required. Boolean value to enable or disable resource lock.')
param resourceLockEnabled bool
@description('Optional. Date in the format yyyy-MM-dd.')
param createdDate string = utcNow('yyyy-MM-dd')
@description('Optional. Date in the format yyyyMMdd-HHmmss.')
param deploymentDate string = utcNow('yyyyMMdd-HHmmss')
@description('Required. The Route Table object.')
param routeTable object

var commonTags = {
  Location: location
  CreatedDate: createdDate
  Environment: environment
  Purpose: 'IPAFFS-VIRTUAL-NETWORK'
}
var tags = union(loadJsonContent('default-tags.json'), commonTags)

module route_aks 'br/SharedDefraRegistry:network.route-table:0.4.2' = {
  name: 'route-table-aks-${deploymentDate}'
  params: {
    name: '${routeTable.name}-AKS'
    lock: resourceLockEnabled ? 'CanNotDelete' : null
    location: location
    tags: tags
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'Default'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: routeTable.virtualApplicanceIp
        }
      }
    ]
  }
}

module virtualNetwork 'br/SharedDefraRegistry:network.virtual-network:0.4.2' = {
  name: 'virtual-network-${deploymentDate}'
  params: {
    name: vnet.name
    location: location
    lock: resourceLockEnabled ? 'CanNotDelete' : null
    tags: tags
    enableDefaultTelemetry: true
    addressPrefixes: vnet.addressPrefixes
    dnsServers: vnet.dnsServers
    subnets: subnets
  }
}
