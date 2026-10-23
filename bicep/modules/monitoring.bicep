targetScope = 'resourceGroup'

param monitoringParams object
param deployServicePrincipalObjectId string
param deploymentId string
param location string
param tags object

var monitoringReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var monitoringDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b0d8363b-8ddd-447d-831f-62ca05bff136')

// Azure Managed Grafana built-in roles for the tenant
var grafanaAdminRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41')

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: monitoringParams.logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
}

resource prometheus 'Microsoft.Monitor/accounts@2025-10-03' = {
  name: monitoringParams.prometheusName
  location: location
  tags: tags
  properties: {
    metrics: {
      enableAccessUsingResourcePermissions: false
    }
  }
}

resource grafanaDashboard 'Microsoft.Dashboard/grafana@2025-08-01' = {
  name: monitoringParams.grafanaName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: [
        {
          azureMonitorWorkspaceResourceId: prometheus.id
        }
      ]
    }
  }
}

// Deploy service principal (ADO service connection) needs Grafana Admin directly
// to manage dashboards and datasources
module grafanaDeploySpAdmin './grafana-role-assignment.bicep' = {
  name: 'grafanaDeploySpAdmin-${deploymentId}'
  scope: resourceGroup()
  params: {
    grafanaName: grafanaDashboard.name
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
    principalObjectId: grafanaDashboard.identity.principalId
    roleDefinitionId: monitoringReaderRoleId
  }
}

module grafanaMonitoringDataReader './prometheus-role-assignment.bicep' = {
  name: 'grafanaMonitoringDataReader-${deploymentId}'
  scope: resourceGroup()
  params: {
    prometheusName: monitoringParams.prometheusName
    deploymentId: deploymentId
    principalObjectId: grafanaDashboard.identity.principalId
    principalType: 'ServicePrincipal'
    roleAssignmentType: 'permanent'
    roleDefinitionId: monitoringDataReaderRoleId
  }
}

output logAnalyticsId string = logAnalytics.id
output grafanaManagedIdentityPrincipalId string = grafanaDashboard.identity.principalId
output grafanaName string = grafanaDashboard.name
output prometheusName string = prometheus.name
