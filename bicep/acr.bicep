param name string
param location string = resourceGroup().location
param sku string = 'Premium' // Options: Basic, Standard, Premium
param adminEnabled bool = true
param subnetId string  
param aksName string  

var acrPullRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
)

resource aks 'Microsoft.ContainerService/managedClusters@2023-01-01' existing = {
  name: aksName
}

resource userPool 'Microsoft.ContainerService/managedClusters/agentPools@2023-08-01' existing = {
  name: '${aksName}/user'
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: name
  location: location
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: adminEnabled
  }
}

resource acrPe 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: name
  location: location
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'acr-connection'
        properties: {
          privateLinkServiceId: acr.id
          groupIds: [
            'registry'
          ]
        }
      }
    ]
  }
}

var kubeletObjectId = aks.properties.identityProfile['kubeletidentity'].objectId

var userPoolRef = reference(userPool.id, '2023-08-01', 'full')
var userPoolKubeletObjectId = userPoolRef.identity.principalId

resource acrPullToAks 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: kubeletObjectId
    principalType: 'ServicePrincipal'
  }
}

resource acrPullToUserPool 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acrPullRoleId, 'user')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: userPoolKubeletObjectId
    principalType: 'ServicePrincipal'
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output acrResourceId string = acr.id
