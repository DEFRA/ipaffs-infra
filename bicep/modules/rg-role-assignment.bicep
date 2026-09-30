/*
  ============================================================================
  DEPRECATED — DO NOT USE
  ============================================================================

  This module is deprecated and will be removed in a future release.
  Use resource-group-role-assignment.bicep instead.

  Reason: the role assignment name is derived from
    guid(resourceGroup().id, principalObjectId, roleDefinitionId)
  which is inconsistent with the naming used by the other resources.
  ============================================================================
*/

targetScope = 'resourceGroup'

param deploymentId string
param roleDefinitionId string
param principalObjectId string


resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalObjectId, roleDefinitionId)
  properties: {
    principalId: principalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}
