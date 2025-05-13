param location string = resourceGroup().location
param bastionVnetName string = 'POCIMPINFVN1042'
param bastionSubnetName string = 'AzureBastionSubnet'
param bastionPublicIPName string = 'POCIMPINFPI1042'
param bastionHostName string = 'POCIMPINFBS1401'

resource bastionVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: bastionVnetName
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: bastionSubnetName
  parent: bastionVnet
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' existing = {
  name: bastionPublicIPName
}

resource bastion 'Microsoft.Network/bastionHosts@2022-07-01' = {
  name: bastionHostName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: '${bastionHostName}-ip-config'
        properties: {
          subnet: {
            id: bastionSubnet.id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}
