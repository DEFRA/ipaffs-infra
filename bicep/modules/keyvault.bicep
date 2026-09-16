targetScope = 'resourceGroup'

param deploymentId string
param location string
param keyVaultParams object
param roleAssignments array
param subnets object
param tags object
param tenantId string

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: keyVaultParams.name
  location: location
  tags: tags

  properties: {
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    tenantId: tenantId

    sku: {
      name: 'standard'
      family: 'A'
    }

    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

resource keyVaultPrivateEndpoints 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${keyVaultParams.name}-${subnets.privateEndpoints.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnets.privateEndpoints.id
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

module keyVaultRoleAssignment './keyvault-role-assignment.bicep' = [for assignment in roleAssignments: {
  name: format('keyVaultRoleAssignment-{0}-{1}', deploymentId, substring(uniqueString(keyVaultParams.name, assignment.roleDefinitionId, assignment.principalObjectId), 0, 7))
  scope: resourceGroup()
  params: {
    keyVaultName: keyVaultParams.name
    deploymentId: deploymentId
    location: location
    principalObjectId: assignment.principalObjectId
    principalType: assignment.principalType
    roleDefinitionId: assignment.roleDefinitionId
  }
}]

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
