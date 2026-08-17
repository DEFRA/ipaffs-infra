targetScope = 'resourceGroup'


@allowed(['DEV', 'TST', 'PRE', 'PRD'])
param environment string
param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location
var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})
param builtInGroups object
param monitoringParams object
param entraGroups object
param prometheusId string
param grafanaId string
param deployServicePrincipalObjectId string
param grafanaManagedIdentityPrincipalId string

module monitoring './modules/monitoring-to-classic.bicep' = {
  name: 'monitoring-to-classic-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    location: location
    tags: tags
    monitoringParams: monitoringParams
    entraGroups: entraGroups
    deployServicePrincipalObjectId: deployServicePrincipalObjectId
    grafanaManagedIdentityPrincipalId: grafanaManagedIdentityPrincipalId
  }
}
