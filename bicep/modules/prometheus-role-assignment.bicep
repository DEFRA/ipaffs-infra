targetScope = 'resourceGroup'

param prometheusName string
param deploymentId string
param principalObjectId string
param principalType string
param roleDefinitionId string

resource prometheus 'Microsoft.Monitor/accounts@2025-10-03' existing = {
  name: prometheusName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(prometheus.id, roleDefinitionId, principalObjectId)
  scope: prometheus
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

// vim: set ts=2 sts=2 sw=2 et:
