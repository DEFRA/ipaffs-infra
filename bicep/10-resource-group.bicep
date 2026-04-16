targetScope = 'subscription'

param name string

@allowed(['DEV', 'TST', 'PRE', 'PRD'])
param environment string

@allowed(['northeuropa', 'uksouth'])
param location string

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

output resourceGroupId string = rg.id

// vim: set ts=2 sts=2 sw=2 et:
