targetScope = 'resourceGroup'

param deploymentId string
param principalObjectId string
param principalType string
param roleAssignmentType string
param roleDefinitionId string
param storageAccountName string

var justification = format('Assign eligible role {0} to {1} {2}', roleDefinitionId, principalType, principalObjectId)

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (roleAssignmentType == 'permanent') {
  name: guid(storageAccount.id, roleDefinitionId, principalObjectId)
  scope: storageAccount
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

resource roleEligibility 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = if (roleAssignmentType == 'eligible') {
  name: guid(storageAccount.id, roleDefinitionId, principalObjectId, deploymentId)
  scope: storageAccount
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
