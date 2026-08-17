targetScope = 'resourceGroup'

param monitoringParams object
param entraGroups object
param subscriptionId string
param resourceGroupName string
param deployServicePrincipalObjectId string
param grafanaManagedIdentityPrincipalId string
param deploymentId string
param location string
param tags object

var monitoringReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var monitoringDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b0d8363b-8ddd-447d-831f-62ca05bff136')

// Azure Managed Grafana built-in roles for the tenant
var grafanaAdminRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41')
var grafanaEditorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a79a5197-3a5c-4973-a920-486035ffd60f')
var grafanaViewerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '60921a7e-fef1-4a43-9b16-a26c52ad4769')


// Team group Grafana access mapping : ProjAdmins -> Admin, Developers ->
// Editor, Readers -> Viewer (groups created + populated by entra-groups.yaml).
module grafanaAdmins './grafana-role-assignment.bicep' = {
  name: 'grafanaAdmins-${deploymentId}'
  scope: resourceGroup()
  params: {
    grafanaName: monitoringParams.grafanaName
    subscriptionId: subscriptionId
    resourceGroupName: resourceGroupName
    deploymentId: deploymentId
    principalObjectId: entraGroups.grafanaAdmins.id
    principalType: 'Group'
    roleDefinitionId: grafanaAdminRoleId
  }
}

module grafanaEditors './grafana-role-assignment.bicep' = {
  name: 'grafanaEditors-${deploymentId}'
  scope: resourceGroup()
  params: {
    grafanaName: monitoringParams.grafanaName
    subscriptionId: subscriptionId
    resourceGroupName: resourceGroupName
    deploymentId: deploymentId
    principalObjectId: entraGroups.grafanaEditors.id
    principalType: 'Group'
    roleDefinitionId: grafanaEditorRoleId
  }
}

module grafanaViewers './grafana-role-assignment.bicep' = {
  name: 'grafanaViewers-${deploymentId}'
  scope: resourceGroup()
  params: {
    grafanaName: monitoringParams.grafanaName
    subscriptionId: subscriptionId
    resourceGroupName: resourceGroupName
    deploymentId: deploymentId
    principalObjectId: entraGroups.grafanaViewers.id
    principalType: 'Group'
    roleDefinitionId: grafanaViewerRoleId
  }
}

// Deploy service principal (ADO service connection) needs Grafana Admin directly
// to manage dashboards and datasources
module grafanaDeploySpAdmin './grafana-role-assignment.bicep' = {
  name: 'grafanaDeploySpAdmin-${deploymentId}'
  scope: resourceGroup()
  params: {
    grafanaName: monitoringParams.grafanaName
    subscriptionId: subscriptionId
    resourceGroupName: resourceGroupName
    deploymentId: deploymentId
    principalObjectId: deployServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: grafanaAdminRoleId
  }
}

module grafanaMonitoringReader './rg-role-assignment.bicep' = {
  name: 'grafanaMonitoringReader-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    principalObjectId: grafanaManagedIdentityPrincipalId
    roleDefinitionId: monitoringReaderRoleId
  }
}

module grafanaMonitoringDataReader './prometheus-role-assignment.bicep' = {
  name: 'grafanaMonitoringDataReader-${deploymentId}'
  scope: resourceGroup()
  params: {
    prometheusName: monitoringParams.prometheusName
    subscriptionId: subscriptionId
    resourceGroupName: resourceGroupName
    deploymentId: deploymentId
    principalObjectId: grafanaManagedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringDataReaderRoleId
  }
}
