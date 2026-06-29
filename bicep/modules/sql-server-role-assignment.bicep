targetScope = 'resourceGroup'

param deploymentId string
param principalObjectId string
param principalType string
param roleDefinitionId string
param sqlServerName string

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlServerName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sqlServer.id, roleDefinitionId, principalObjectId)
  scope: sqlServer
  properties: {
    principalId: principalObjectId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

