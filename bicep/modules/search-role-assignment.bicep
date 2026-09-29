targetScope = 'resourceGroup'

param searchServiceName string
param deploymentId string
param principalObjectId string
param principalType string
param roleAssignmentType string
param roleDefinitionId string

var justification = format('Assign eligible role {0} to {1} {2}', roleDefinitionId, principalType, principalObjectId)

resource searchService 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: searchServiceName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (roleAssignmentType == 'permanent') {
  name: guid(searchService.id, roleDefinitionId, principalObjectId)
  scope: searchService
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

resource roleEligibility 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = if (roleAssignmentType == 'eligible') {
  name: guid(searchService.id, roleDefinitionId, principalObjectId, deploymentId)
  scope: searchService
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
