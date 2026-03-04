targetScope = 'resourceGroup'

param deploymentId string
param entraGroups object
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
    enableRbacAuthorization: true
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

var keyVaultAdministratorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

module keyVaultAdministrator './keyvault-role-assignment.bicep' = {
  name: 'keyVaultAdministrator-${deploymentId}'
  scope: resourceGroup()
  params: {
    keyVaultName: keyVaultParams.name
    deploymentId: deploymentId
    location: location
    principalObjectId: entraGroups.keyVaultAdmins.id
    principalType: 'Group'
    roleDefinitionId: keyVaultAdministratorRoleId
  }
}

module keyVaultSecretsReader './keyvault-role-assignment.bicep' = {
  name: 'keyVaultSecretsReader-${deploymentId}'
  scope: resourceGroup()
  params: {
    keyVaultName: keyVaultParams.name
    deploymentId: deploymentId
    location: location
    principalObjectId: entraGroups.keyVaultSecretsReaders.id
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
