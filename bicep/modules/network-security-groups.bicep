targetScope = 'resourceGroup'

param deploymentId string
param location string
param nsgParams object
param tags object

module networkSecurityGroup 'br/SharedDefraRegistry:network.network-security-group:0.4.2' = [for nsg in nsgParams.networkSecurityGroups:  {
  name: '${nsg.name}-${deploymentId}'
  params: {
    name: nsg.name
    location: location
    lock: ''
    tags: tags
    securityRules: nsg.securityRules 
  }
}]

