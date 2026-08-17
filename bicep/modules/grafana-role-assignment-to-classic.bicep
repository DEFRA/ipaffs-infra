targetScope = 'resourceGroup'

param grafanaId string
param deploymentId string
param principalObjectId string
param principalType string
param roleDefinitionId string

resource grafana 'Microsoft.Dashboard/grafana@2025-08-01' existing = {
  name: last(split(grafanaId, '/'))
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(grafanaId, roleDefinitionId, principalObjectId)
  scope: grafana
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}
