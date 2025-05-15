param location string = resourceGroup().location
param aksVnetName string = 'POCIMPINFVN1401'
param aksSubnetName string = 'POCIMPINFSU1401'
//param natGatewayName string = 'POCIMPINFNG1401'
//param publicIPName string = 'POCIMPINFPI1401'
//param routeTableName string = 'POCIMPINFRT1401'
//param bastionVnetName string = 'POCIMPINFVN1042'
//param bastionSubnetName string = 'AzureBastionSubnet'
//param bastionPublicIPName string = 'POCIMPINFPI1042'

/*
resource publicIP 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIPName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
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
*/
resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: '${aksVnetName}-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'defaultRoute'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

resource aksVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: aksVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: aksSubnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
//          natGateway: {
//            id: natGateway.id
//          }
          routeTable: {
            id: routeTable.id
          }
        }
      }
    ]
  }
}
/*
resource bastionVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: bastionVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.100.0.0/16'
      ]
    }
    subnets: [
      {
        name: bastionSubnetName
        properties: {
          addressPrefix: '10.100.1.0/24'
        }
      }
    ]
  }
}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: bastionPublicIPName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}
*/

output aksVnetId string = aksVnet.id
//output bastionVnetId string = bastionVnet.id
output aksSubnetId string = aksVnet.properties.subnets[0].id
//output bastionSubnetId string = bastionVnet.properties.subnets[0].id
//output bastionPublicIPName string = bastionPip.name

