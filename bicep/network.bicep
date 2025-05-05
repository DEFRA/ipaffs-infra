param location string = resourceGroup().location
param vnetName string = 'ipaffs-vnet'
param subnetName string = 'aks-subnet'
param natGatewayName string = 'ipaffs-nat'
param publicIPName string = 'ipaffs-nat-ip'

resource publicIP 'Microsoft.Network/publicIPAddresses@2022-07-01' = {
  name: publicIPName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2022-07-01' = {
  name: natGatewayName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: publicIP.id
      }
    ]
    idleTimeoutInMinutes: 10
  }
}

resource routeTable 'Microsoft.Network/routeTables@2022-07-01' = {
  name: 'aks-udr'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          natGateway: {
            id: natGateway.id
          }
          routeTable: {
            id: routeTable.id
          }
        }
      }
    ]
  }
}

output subnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  vnet.name,
  subnetName
)
