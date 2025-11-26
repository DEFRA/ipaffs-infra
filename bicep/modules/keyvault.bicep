targetScope = 'resourceGroup'

param location string
param keyVaultParams object
param subnetIds array
param tags object

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultParams.name
  location: location
  tags: tags

  properties: {
    publicNetworkAccess: 'Disabled'
    tenantId: keyVaultParams.tenantId

    sku: {
      name: 'standard'
      family: 'A'
    }

    accessPolicies: [for objectId in keyVaultParams.principalObjectIds: {
      tenantId: keyVaultParams.tenantId
      objectId: objectId
      permissions: {
        secrets: [
          'get'
          'list'
          'set'
          'delete'
        ]
      }
    }]

    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

resource keyVaultPrivateEndpoints 'Microsoft.Network/privateEndpoints@2024-10-01' = [for subnetId in subnetIds: {
  name: '${keyVaultParams.name}-${last(split(subnetId, '/'))}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnetId
    }

    privateLinkServiceConnections: [
      {
        name: 'keyvault-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}]

//resource dnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
//  name: 'dns-link'
//  parent: privateDnsZone
//
//  properties: {
//    registrationEnabled: false
//
//    virtualNetwork: {
//      id: vnetId
//    }
//  }
//}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
