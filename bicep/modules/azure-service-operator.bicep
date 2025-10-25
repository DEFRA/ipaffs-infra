targetScope = 'resourceGroup'

param asoParams object
param location string
param oidcIssuerUrl string
param tags object

var namespace = 'azureserviceoperator-system'
var serviceAccount = 'azureserviceoperator-default'

var contributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: asoParams.managedIdentityName
  location: location
  tags: tags
}

resource credential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: managedIdentity
  name: 'azure-service-operator'
  properties: {
    audiences: ['api://AzureADTokenExchange']
    issuer: oidcIssuerUrl
    subject: 'system:serviceaccount:${namespace}:${serviceAccount}'
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, contributorRoleId, asoParams.managedIdentityName)
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributorRoleId
  }
}

output clientId string = managedIdentity.properties.clientId
output principalObjectId string = managedIdentity.properties.principalId

// vim: set ts=2 sts=2 sw=2 et:
