targetScope = 'resourceGroup'

param monitoringParams object
param deploymentId string
param location string
param tags object

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: monitoringParams.logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018' // Note: will 'Free' SKU work?
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
}

resource prometheus 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: monitoringParams.prometheusName
  location: location
  tags: tags
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

resource grafanaAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, monitoringParams.principalObjectId, 'Grafana Admin')
  scope: grafanaDashboard
  properties: {
    principalId: monitoringParams.principalObjectId
    principalType: 'Group'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41')
  }
}

// vim: set ts=2 sts=2 sw=2 et:

