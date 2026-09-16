targetScope = 'resourceGroup'

param location string
param tags object
param config object

// Public frontend responses must return directly, not via the shared AKS NVA.
resource routeTable 'Microsoft.Network/routeTables@2025-05-01' = {
  name: config.routeTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'DefaultInternetRoute'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

output routeTableId string = routeTable.id
