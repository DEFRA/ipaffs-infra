targetScope = 'resourceGroup'

param deploymentId string
param principalObjectId string
param principalType string
param roleAssignmentType string
param roleDefinitionId string

var justification = format('Assign eligible role {0} to {1} {2}', roleDefinitionId, principalType, principalObjectId)

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (roleAssignmentType == 'permanent') {
  name: guid(resourceGroup().id, roleDefinitionId, principalObjectId)
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

resource roleEligibility 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = if (roleAssignmentType == 'eligible') {
  name: guid(resourceGroup().id, roleDefinitionId, principalObjectId, deploymentId)
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
