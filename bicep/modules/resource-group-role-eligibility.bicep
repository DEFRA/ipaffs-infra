targetScope = 'resourceGroup'

param justification string
param principalObjectId string
param roleDefinitionId string
param endDateTime string

resource roleEligibility 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = {
  name: guid(resourceGroup().id, roleDefinitionId, principalObjectId)
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
