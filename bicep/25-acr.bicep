targetScope = 'resourceGroup'

@allowed(['DEV', 'PRD'])
param environment string

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param entraGroups object
param location string = resourceGroup().location
param subnets object

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

param acrParams object

module acr './modules/acr.bicep' = {
  name: 'acr-${deploymentId}'
  scope: resourceGroup()
  params: {
    acrParams: acrParams
    deploymentId: deploymentId
    entraGroups: entraGroups
    location: location
    subnets: subnets
    tags: tags
  }
}

output acrName string = acr.outputs.acrName
output acrLoginServer string = acr.outputs.acrLoginServer
output acrResourceId string = acr.outputs.acrResourceId

// vim: set ts=2 sts=2 sw=2 et:
