targetScope = 'resourceGroup'

param agcParams object
param aksNodeResourceGroupName string
param deploymentId string
param location string
param oidcIssuerUrl string
param subnetName string
param tags object
param vnetName string

// Network resources remain owned exclusively by 20-network.bicep.
resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2025-05-01' existing = {
  parent: vnet
  name: subnetName
}

resource controllerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: agcParams.managedIdentityName
  location: location
  tags: tags
}

resource credential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: controllerIdentity
  name: 'azure-alb-identity'
  properties: {
    audiences: ['api://AzureADTokenExchange']
    issuer: oidcIssuerUrl
    subject: 'system:serviceaccount:${agcParams.controllerNamespace}:alb-controller-sa'
  }
}

// BYO deployment: Azure owns the gateway/association/frontend lifecycle, not a CR.
resource agc 'Microsoft.ServiceNetworking/trafficControllers@2025-01-01' = {
  name: agcParams.name
  location: location
  tags: tags
  properties: {}
}

resource association 'Microsoft.ServiceNetworking/trafficControllers/associations@2025-01-01' = {
  parent: agc
  name: agcParams.associationName
  location: location
  tags: tags
  properties: {
    associationType: 'subnets'
    subnet: {
      id: subnet.id
    }
  }
}

resource frontend 'Microsoft.ServiceNetworking/trafficControllers/frontends@2025-01-01' = {
  parent: agc
  name: agcParams.frontendName
  location: location
  tags: tags
  properties: {}
}

// Use Microsoft's documented BYO scopes; never grant subscription-wide access.
module configurationManager './rg-role-assignment.bicep' = {
  name: 'agc-config-manager-${deploymentId}'
  scope: resourceGroup()
  params: {
    deploymentId: deploymentId
    principalObjectId: controllerIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fbc52c3f-28ad-4303-a892-8a056630b8f1')
  }
}

module subnetNetworkContributor './subnet-role-assignment.bicep' = {
  name: 'agc-subnet-contributor-${deploymentId}'
  scope: resourceGroup()
  params: {
    principalObjectId: controllerIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
    subnetName: subnetName
    vnetName: vnetName
  }
}

// Discover AKS-managed networking without granting write access to the node RG.
module nodeResourceGroupReader './rg-role-assignment.bicep' = {
  name: 'agc-node-rg-reader-${deploymentId}'
  scope: resourceGroup(aksNodeResourceGroupName)
  params: {
    deploymentId: deploymentId
    principalObjectId: controllerIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}

output controllerClientId string = controllerIdentity.properties.clientId
output controllerPrincipalId string = controllerIdentity.properties.principalId
output agcResourceId string = agc.id
output frontendName string = agcParams.frontendName
output frontendFqdn string = frontend.properties.fqdn
