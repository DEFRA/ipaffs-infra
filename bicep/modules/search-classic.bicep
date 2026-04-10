targetScope = 'resourceGroup'

param deploymentId string
param entraGroups object
param location string
param privateEndpointsSubnet object
param searchParams object
param tags object

resource searchService 'Microsoft.Search/searchServices@2015-08-19' existing = {
  name: searchParams.name
}

resource searchServicePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${searchParams.name}-${privateEndpointsSubnet.name}'
  location: location
  tags: tags

  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
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

// TODO: do we want these outputs?
//output searchServiceSubscriptionId string = subscription().subscriptionId
//output searchServiceResourceGroupName string = resourceGroup().name
//output searchServiceName string = searchService.name
//output searchServiceId string = searchService.id
//output searchServiceEndpoint string = searchService.properties.endpoint
//output searchServiceManagedIdentityPrincipalName string = userAssignedIdentity.name
//output searchServiceManagedIdentityPrincipalId string = userAssignedIdentity.properties.principalId
