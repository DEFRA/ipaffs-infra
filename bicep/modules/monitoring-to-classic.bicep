targetScope = 'resourceGroup'

param monitoringParams object
param entraGroups object
param deployServicePrincipalObjectId string
param grafanaManagedIdentityPrincipalId string
param deploymentId string
param location string
param tags object

var monitoringReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var monitoringDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b0d8363b-8ddd-447d-831f-62ca05bff136')



module grafanaMonitoringReader './rg-role-assignment.bicep' = {
  name: 'grafanaMonitoringReader-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    principalObjectId: grafanaManagedIdentityPrincipalId
    roleDefinitionId: monitoringReaderRoleId
  }
}
