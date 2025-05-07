param name string
param location string = resourceGroup().location
param tenantId string
param objectId string
param vnetResourceGroup string
param vnetName string
param subnetName string
param dnsZoneName string = 'privatelink.vaultcore.azure.net'

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: name
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    accessPolicies: [
      {
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
      }
    ]
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

// Get existing subnet from another RG
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  name: subnetName
  parent: resourceId(vnetResourceGroup, 'Microsoft.Network/virtualNetworks', vnetName)
}

// Private endpoint
resource pe 'Microsoft.Network/privateEndpoints@2022-07-01' = {
  name: '${name}-pe'
  location: location
  properties: {
    subnet: {
      id: subnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'keyVaultConnection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [ 'vault' ]
        }
      }
    ]
  }
}

// DNS zone for vaultcore
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dnsZoneName
  location: 'global'
}

// DNS zone link to VNet
resource dnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: 'dns-link'
  parent: privateDnsZone
  properties: {
    virtualNetwork: {
      id: subnet.parent
    }
    registrationEnabled: false
  }
}

// DNS record for vault
resource dnsRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  name: '${name}.vaultcore.azure.net'
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
