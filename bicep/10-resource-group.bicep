targetScope = 'subscription'

@allowed(['DEV', 'TST', 'PRE', 'PRD'])
param environment string

@allowed(['northeuropa', 'uksouth'])
param location string

param name string
param entraGroups object = {}
param pimEligibilityEndDateTime string
param principalsNeedingReader array

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: name
  location: location
  tags: tags
}

var ownerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
var contributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')

module additionalReaders './modules/resource-group-role-assignment.bicep' = [for principalId in principalsNeedingReader: {
  name: format('additionalReaders-{0}-{1}', deploymentId, substring(uniqueString(principalId), 0, 7))
  scope: rg
  params: {
    deploymentId: deploymentId
    principalObjectId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRoleId
  }
}]

module pimOwnersEligibility './modules/resource-group-role-eligibility.bicep' = if (!empty(entraGroups.pimOwners.id)) {
  name: format('pimOwnersEligibility-{0}', deploymentId)
  scope: rg
  params: {
    justification: 'Assign eligible Owner role to ${entraGroups.pimOwners.name}'
    principalObjectId: entraGroups.pimOwners.id
    roleDefinitionId: ownerRoleId
    endDateTime: pimEligibilityEndDateTime
  }
}

module pimContributorsEligibility './modules/resource-group-role-eligibility.bicep' = if (!empty(entraGroups.pimContributors.id)) {
  name: format('pimContributorsEligibility-{0}', deploymentId)
  scope: rg
  params: {
    justification: 'Assign eligible Contributor role to ${entraGroups.pimContributors.name}'
    principalObjectId: entraGroups.pimContributors.id
    roleDefinitionId: contributorRoleId
    endDateTime: pimEligibilityEndDateTime
  }
}

output resourceGroupId string = rg.id

