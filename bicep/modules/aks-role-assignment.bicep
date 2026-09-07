targetScope = 'resourceGroup'

param aksName string
param deploymentId string
param principalObjectId string
param principalType string
param roleAssignmentType string
param roleDefinitionId string

var justification = format('Assign eligible role {0} to {1} {2}', roleDefinitionId, principalType, principalObjectId)

resource aks 'Microsoft.ContainerService/managedClusters@2025-10-01' existing = {
  name: aksName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (roleAssignmentType == 'permanent') {
  name: guid(aks.id, roleDefinitionId, principalObjectId)
  scope: aks
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

resource roleEligibility 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = if (roleAssignmentType == 'eligible') {
  name: guid(aks.id, roleDefinitionId, principalObjectId, deploymentId)
  scope: aks
  properties: {
    justification: justification
    principalId: principalObjectId
    requestType: 'AdminUpdate'
    roleDefinitionId: roleDefinitionId
    scheduleInfo: {
      expiration: {
        type: 'AfterDuration'
        duration: 'P365D'
      }
    }
  }
}
