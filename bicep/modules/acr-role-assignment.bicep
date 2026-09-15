targetScope = 'resourceGroup'

param acrName string
param deploymentId string
param principalObjectId string
param principalType string
param roleAssignmentType string
param roleDefinitionId string

var justification = format('Assign eligible role {0} to {1} {2}', roleDefinitionId, principalType, principalObjectId)

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: acrName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (roleAssignmentType == 'permanent') {
  name: guid(acr.id, roleDefinitionId, principalObjectId)
  scope: acr
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

resource roleEligibility 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = if (roleAssignmentType == 'eligible') {
  name: guid(acr.id, roleDefinitionId, principalObjectId, deploymentId)
  scope: acr
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
