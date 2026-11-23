// This API adds AzureContainerLinux to the supported node pool OS SKUs.
param config object
param apiSettings object

var additionalProperties = {
  hostedSystemProfile: apiSettings.hostedSystemProfile
  ingressProfile: {
    webAppRouting: {
      gatewayAPIImplementations: apiSettings.gatewayAPIImplementations
    }
  }
  networkProfile: {
    advancedNetworking: apiSettings.advancedNetworking
  }
}

resource aksCluster 'Microsoft.ContainerService/managedClusters@2026-03-01' = {
  name: config.name
  location: config.location
  tags: config.tags
  kind: config.kind
  identity: config.identity
  properties: union(config.properties, additionalProperties)
  sku: config.sku
}

output kubeletPrincipalId string = aksCluster.properties.identityProfile.kubeletIdentity.objectId
output oidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL
