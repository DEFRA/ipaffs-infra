targetScope = 'resourceGroup'

param externalSecretsParams object
param deploymentId string
param location string
param oidcIssuerUrl string
param tags object

var namespace = 'external-secrets'
var serviceAccount = 'external-secrets'

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: externalSecretsParams.managedIdentityName
  location: location
  tags: tags
}

resource credential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: managedIdentity
  name: 'external-secrets'
  properties: {
    audiences: ['api://AzureADTokenExchange']
    issuer: oidcIssuerUrl
    subject: 'system:serviceaccount:${namespace}:${serviceAccount}'
  }
}

output clientId string = managedIdentity.properties.clientId
output principalObjectId string = managedIdentity.properties.principalId

// vim: set ts=2 sts=2 sw=2 et:
