targetScope = 'resourceGroup'

param deploymentId string
param location string
param searchParams object
param sqlServerName string
param tags object

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: searchParams.userAssignedIdentityName
  location: location
  tags: tags
}

var sqlServerContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437')

module sqlServerContributor './sql-server-role-assignment.bicep' = {
  name: 'sqlServerContributor-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    principalObjectId: userAssignedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleAssignmentType: 'permanent'
    roleDefinitionId: sqlServerContributorRoleId
    sqlServerName: sqlServerName
  }
}

// TODO: adopt search service in order to apply user assigned managed identity
resource searchService 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: searchParams.name
}


output searchServiceSubscriptionId string = subscription().subscriptionId
output searchServiceResourceGroupName string = resourceGroup().name
output searchServiceName string = searchService.name
output searchServiceResourceId string = searchService.id
output searchServiceEndpoint string = searchService.properties.endpoint
output searchServiceManagedIdentityPrincipalName string = userAssignedIdentity.name
output searchServiceManagedIdentityPrincipalId string = userAssignedIdentity.properties.principalId
