targetScope = 'resourceGroup'

param deploymentId string
param location string
param searchParams object
param sqlServerName string
param subnets object
param tags object
param tenantId string

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: searchParams.userAssignedIdentityName
  location: location
  tags: tags
}

var sqlServerContributorId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437')

module sqlServerContributor './sql-server-role-assignment.bicep' = {
  name: 'sqlServerContributor-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    principalObjectId: userAssignedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleAssignmentType: 'permanent'
    roleDefinitionId: sqlServerContributorId
    sqlServerName: sqlServerName
  }
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlServerName
}

resource searchService 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchParams.name
  location: location
  tags: tags

  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }

  sku: {
    name: 'standard'
  }

  properties: {
    computeType: 'Default'
    partitionCount: searchParams.partitionCount
    replicaCount: searchParams.replicaCount
    semanticSearch: 'disabled'

    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }

    publicNetworkAccess: 'Disabled'
    networkRuleSet: {
      bypass: 'AzureServices'
    }
  }
}

resource searchSqlSharedPrivateLink 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01' = {
  parent: searchService
  name: sqlServerName
  properties: {
    groupId: 'sqlServer'
    privateLinkResourceId: sqlServer.id
    requestMessage: 'Allow Azure AI Search indexers to access SQL Server over private link.'
  }
}

resource searchServicePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${searchParams.name}-${subnets.privateEndpoints.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnets.privateEndpoints.id
    }

    privateLinkServiceConnections: [
      {
        name: 'search-connection'
        properties: {
          privateLinkServiceId: searchService.id
          groupIds: ['searchService']
        }
      }
    ]
  }
}


output searchServiceSubscriptionId string = subscription().subscriptionId
output searchServiceResourceGroupName string = resourceGroup().name
output searchServiceName string = searchService.name
output searchServiceResourceId string = searchService.id
output searchServiceEndpoint string = searchService.properties.endpoint
output searchServiceManagedIdentityPrincipalName string = userAssignedIdentity.name
output searchServiceManagedIdentityPrincipalId string = userAssignedIdentity.properties.principalId
