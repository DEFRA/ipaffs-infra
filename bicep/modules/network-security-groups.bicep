targetScope = 'resourceGroup'

param deploymentId string
param location string
param nsgParams object
param tags object

module networkSecurityGroup './network-security-group.bicep' = [for nsg in nsgParams.networkSecurityGroups: {
  name: '${nsg.name}-${deploymentId}'
  params: {
    name: nsg.name
    location: location
    tags: tags
    securityRules: nsg.securityRules
  }
}]

