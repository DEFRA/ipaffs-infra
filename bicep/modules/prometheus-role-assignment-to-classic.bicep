targetScope = 'resourceGroup'

param prometheusId string
param deploymentId string
param principalObjectId string
param principalType string
param roleDefinitionId string

resource prometheus 'Microsoft.Monitor/accounts@2025-10-03' existing = {
  name: last(split(prometheusId, '/'))
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(prometheusId, roleDefinitionId, principalObjectId)
  scope: prometheus
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

