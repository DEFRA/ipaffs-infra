param location string = resourceGroup().location
param keyVaultProperties object
param vnetId string
param subnetId string
param dnsZoneName string = 'privatelink.vaultcore.azure.net'

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultProperties.name
  location: location
  properties: {
    tenantId: keyVaultProperties.tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    accessPolicies: [for objectId in keyVaultProperties.principalObjectIds: {
      tenantId: keyVaultProperties.tenantId
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
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

// Private endpoint
resource pe 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${keyVaultProperties.name}-pe'
  location: location
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'keyVaultConnection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

// DNS zone for vaultcore
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: dnsZoneName
  location: 'global'
}

// DNS zone link to VNet
resource dnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  name: 'dns-link'
  parent: privateDnsZone
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

// DNS record for vault
resource dnsRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  name: '${keyVaultProperties.name}.vaultcore.azure.net'
  parent: privateDnsZone
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: pe.properties.customDnsConfigs[0].ipAddresses[0]
      }
    ]
  }
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
