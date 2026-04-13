targetScope = 'resourceGroup'

param deploymentId string
param entraGroups object
param location string
param storageParams object
param subnets object
param tags object

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageParams.name
  location: location
  tags: tags

  identity: {
    type: 'SystemAssigned'
  }

  sku: {
    name: 'Standard_GRS'
    tier: 'Standard'
  }

  kind: 'StorageV2'

  properties: {
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: true
    networkAcls: {
      resourceAccessRules: []
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
      defaultAction: 'Deny'
    }
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
    accessTier: 'Hot'
  }
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${storageParams.name}-${subnets.privateEndpoints.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnets.privateEndpoints.id
    }

    privateLinkServiceConnections: [
      {
        name: 'storage-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
  sku: {
    name: 'Standard_GRS'
    tier: 'Standard'
  }
  properties: {
    changeFeed: {
      enabled: true
    }
    restorePolicy: {
      enabled: true
      days: 29
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    cors: {
      corsRules: []
    }
    deleteRetentionPolicy: {
      allowPermanentDelete: false
      enabled: true
      days: 30
    }
    isVersioningEnabled: true
  }
}

var storageBlobDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var storageBlobDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')

module blobStorageContributor './storage-role-assignment.bicep' = {
  name: 'blobStorageContributor-${deploymentId}'
  scope: resourceGroup()
  params: {
    storageAccountName: storageParams.name
    deploymentId: deploymentId
    principalObjectId: entraGroups.blobStorageContributors.id
    principalType: 'Group'
    roleDefinitionId: storageBlobDataContributorRoleId
  }
}

module blobStorageReader './storage-role-assignment.bicep' = {
  name: 'blobStorageReader-${deploymentId}'
  scope: resourceGroup()
  params: {
    storageAccountName: storageParams.name
    deploymentId: deploymentId
    principalObjectId: entraGroups.blobStorageReaders.id
    principalType: 'Group'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}


output storageAccountName string = storageAccount.name
