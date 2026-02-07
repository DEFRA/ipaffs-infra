targetScope = 'resourceGroup'

param deploymentId string
param location string
param keyVaultParams object
param subnetNames object
param subnets array
param tags object
param tenantId string

var subnet = first(filter(subnets, subnet => subnet.name == subnetNames.privateEndpoints))

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultParams.name
  location: location
  tags: tags

  properties: {
    publicNetworkAccess: 'Disabled'
    tenantId: tenantId

    sku: {
      name: 'standard'
      family: 'A'
    }

    accessPolicies: [for objectId in keyVaultParams.principalObjectIds: {
      tenantId: tenantId
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

resource keyVaultPrivateEndpoints 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${keyVaultParams.name}-${subnet.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnet.id
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
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
