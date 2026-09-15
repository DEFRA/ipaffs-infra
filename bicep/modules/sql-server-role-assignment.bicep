targetScope = 'resourceGroup'

param deploymentId string
param principalObjectId string
param principalType string
param roleAssignmentType string
param roleDefinitionId string
param sqlServerName string

var justification = format('Assign eligible role {0} to {1} {2}', roleDefinitionId, principalType, principalObjectId)

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlServerName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (roleAssignmentType == 'permanent') {
  name: guid(sqlServer.id, roleDefinitionId, principalObjectId)
  scope: sqlServer
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

resource roleEligibility 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = if (roleAssignmentType == 'eligible') {
  name: guid(sqlServer.id, roleDefinitionId, principalObjectId, deploymentId)
  scope: sqlServer
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
