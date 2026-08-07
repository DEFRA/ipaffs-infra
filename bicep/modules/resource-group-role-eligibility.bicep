targetScope = 'resourceGroup'

param justification string
param principalObjectId string
param roleDefinitionId string

resource roleEligibility 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = {
  name: guid(resourceGroup().id, roleDefinitionId, principalObjectId, 'eligible')
  properties: {
    justification: justification
    principalId: principalObjectId
    requestType: 'AdminAssign'
    roleDefinitionId: roleDefinitionId
    scheduleInfo: {
      expiration: {
        type: 'NoExpiration'
      }
    }
  }
}
