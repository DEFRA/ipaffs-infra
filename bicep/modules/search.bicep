targetScope = 'resourceGroup'

param deploymentId string
param entraGroups object
param location string
param searchParams object
param sqlServerName string
param subnetNames object
param subnets array
param tags object
param tenantId string

var subnet = first(filter(subnets, subnet => subnet.name == subnetNames.privateEndpoints))

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
    roleDefinitionId: sqlServerContributorId
    sqlServerName: searchParams.name
  }
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

resource searchServicePrivateEndpoints 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${searchParams.name}-${subnet.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: subnet.id
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

var searchServiceContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
var searchIndexDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
var searchIndexDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')

module searchServiceContributor './search-role-assignment.bicep' = {
  name: 'searchServiceContributor-${deploymentId}'
  scope: resourceGroup()
  params: {
    searchServiceName: searchParams.name
    deploymentId: deploymentId
    principalObjectId: entraGroups.searchContributors.id
    principalType: 'Group'
    roleDefinitionId: searchServiceContributorRoleId
  }
}

module searchContributor './search-role-assignment.bicep' = {
  name: 'searchContributor-${deploymentId}'
  scope: resourceGroup()
  params: {
    searchServiceName: searchParams.name
    deploymentId: deploymentId
    principalObjectId: entraGroups.searchContributors.id
    principalType: 'Group'
    roleDefinitionId: searchIndexDataContributorRoleId
  }
}

module searchReader './search-role-assignment.bicep' = {
  name: 'searchReader-${deploymentId}'
  scope: resourceGroup()
  params: {
    searchServiceName: searchParams.name
    deploymentId: deploymentId
    principalObjectId: entraGroups.searchReaders.id
    principalType: 'Group'
    roleDefinitionId: searchIndexDataReaderRoleId
  }
}

output searchServiceName string = searchService.name
output searchServiceId string = searchService.id
output searchServiceEndpoint string = searchService.properties.endpoint
output serviceServiceManagedIdentityPrincipalId string = userAssignedIdentity.properties.principalId
