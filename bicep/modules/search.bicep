targetScope = 'resourceGroup'

param deploymentId string
param entraGroups object
param location string
param searchParams object
param subnetNames object
param subnets array
param tags object
param tenantId string

var subnet = first(filter(subnets, subnet => subnet.name == subnetNames.privateEndpoints))

resource searchService 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchParams.name
  location: location
  tags: tags

  identity: {
    type: 'SystemAssigned'
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

var searchIndexDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
var searchIndexDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')

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

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: '${searchParams.name}-${subnet.name}'
  location: location
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

output searchServiceName string = searchService.name
output searchServiceId string = searchService.id
output searchServiceEndpoint string = searchService.properties.endpoint
