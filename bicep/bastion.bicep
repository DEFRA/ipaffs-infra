param location string = resourceGroup().location
//param aksVnetId string
param bastionVnetName string = 'bastion-vnet'

var bastionSubnetName = 'AzureBastionSubnet'
var bastionSubnetPrefix = '10.100.0.0/24'
var bastionAddressSpace = '10.100.0.0/16'
var publicIpName = 'bastion-pip'
var bastionHostName = 'bastion-host'

// Create Bastion VNet
resource bastionVnet 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: bastionVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ bastionAddressSpace ]
    }
    subnets: [
      {
        name: bastionSubnetName
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
    ]
  }
}

// Public IP for Bastion
resource publicIp 'Microsoft.Network/publicIPAddresses@2022-07-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Bastion Host
resource bastionHost 'Microsoft.Network/bastionHosts@2022-07-01' = {
  name: bastionHostName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: {
            id: bastionVnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

output bastionHostName string = bastionHost.name
output bastionPublicIp string = publicIp.properties.ipAddress
output bastionVnetId string = bastionVnet.id
