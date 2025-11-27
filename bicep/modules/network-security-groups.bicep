targetScope = 'resourceGroup'

param deploymentId string
param location string
param nsgParams object
param tags object

param deploymentDate string = utcNow('yyyyMMdd-HHmmss')

module networkSecurityGroup 'br/SharedDefraRegistry:network.network-security-group:0.4.2' = [for nsg in nsgParams.networkSecurityGroups:  {
  name: '${nsg.name}-${deploymentDate}'
  params: {
    name: nsg.name
    location: location
    lock: ''
    tags: tags
    securityRules: nsg.securityRules 
  }
}]

// vim: set ts=2 sts=2 sw=2 et:
