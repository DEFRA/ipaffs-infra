targetScope = 'resourceGroup'

param name string
param location string
param tags object
param virtualApplianceIp string

resource routeTable 'Microsoft.Network/routeTables@2025-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'Default'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: virtualApplianceIp
        }
      }
    ]
  }
}

output resourceId string = routeTable.id
output name string = routeTable.name
