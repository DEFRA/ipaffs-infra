targetScope = 'resourceGroup'

param deploymentId string
param location string
param tags object
param config object

// Separate from the shared AKS NSG: these restrictions apply only to AGC.
module nsg './network-security-groups.bicep' = {
  name: 'agc-nsg-${deploymentId}'
  params: {
    deploymentId: deploymentId
    location: location
    tags: tags
    nsgParams: {
      networkSecurityGroups: [
        {
          name: config.networkSecurityGroupName
          securityRules: [
            {
              name: 'AllowFrontDoorHttps'
              properties: {
                description: 'Allow HTTPS from Front Door; HTTPRoutes must also validate X-Azure-FDID.'
                protocol: 'Tcp'
                sourcePortRange: '*'
                destinationPortRange: '443'
                sourceAddressPrefix: 'AzureFrontDoor.Backend'
                destinationAddressPrefix: '*'
                access: 'Allow'
                priority: 1000
                direction: 'Inbound'
              }
            }
            {
              name: 'AllowAzureLoadBalancer'
              properties: {
                description: 'Required AGC platform connectivity.'
                protocol: '*'
                sourcePortRange: '*'
                destinationPortRange: '*'
                sourceAddressPrefix: 'AzureLoadBalancer'
                destinationAddressPrefix: '*'
                access: 'Allow'
                priority: 1010
                direction: 'Inbound'
              }
            }
            {
              name: 'DenyOtherInbound'
              properties: {
                description: 'Prevent public and VNet callers bypassing Front Door.'
                protocol: '*'
                sourcePortRange: '*'
                destinationPortRange: '*'
                sourceAddressPrefix: '*'
                destinationAddressPrefix: '*'
                access: 'Deny'
                priority: 4096
                direction: 'Inbound'
              }
            }
            {
              name: 'AllowAksPodBackends'
              properties: {
                description: 'Allow backend traffic and health probes to overlay pod target ports.'
                protocol: 'Tcp'
                sourcePortRange: '*'
                destinationPortRange: '*'
                sourceAddressPrefix: '*'
                destinationAddressPrefixes: config.podAddressPrefixes
                access: 'Allow'
                priority: 1000
                direction: 'Outbound'
              }
            }
          ]
        }
      ]
    }
  }
}

// Public frontend responses must return directly, not via the shared AKS NVA.
resource routeTable 'Microsoft.Network/routeTables@2025-05-01' = {
  name: config.routeTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'DefaultInternetRoute'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

// Deliberately retain default outbound NSG rules until platform flows are validated.
output networkSecurityGroupId string = resourceId('Microsoft.Network/networkSecurityGroups', config.networkSecurityGroupName)
output routeTableId string = routeTable.id
