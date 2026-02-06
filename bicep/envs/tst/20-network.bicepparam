using '../../20-network.bicep'
extends 'common.bicepparam'

param nsgParams = {
  networkSecurityGroups: [
    {
      name: 'TSTIMPNETNS1401-AKS'
      purpose: 'AKS'
      securityRules: [
        {
          name: 'AllowInboundPeeredVnet'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '10.176.0.0/23'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 1000
            direction: 'Inbound'
            description: 'Allow all inbound traffic from peered Hub VNet'
          }
        }
        {
          name: 'AllowInboundPlatformVPN'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '172.27.240.0/25'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 1100
            direction: 'Inbound'
            description: 'Allow all inbound traffic from platform VPN'
          }
        }
        {
          name: 'AllowInboundTradeVPN'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '172.27.244.0/26'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 1110
            direction: 'Inbound'
            description: 'Allow all inbound traffic from trade VPN'
          }
        }
        {
          name: 'AllowInboundAVD'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '10.180.7.0/27'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 1120
            direction: 'Inbound'
            description: 'Allow all inbound traffic from AD3 AVD'
          }
        }
        {
          name: 'AllowOutboundPeeredVnet'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: '10.176.0.0/23'
            access: 'Allow'
            priority: 1000
            direction: 'Outbound'
            description: 'Allow all outbound traffic to peered Hub VNet'
          }
        }
        {
          name: 'AllowVnetToAksServiceCidr'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: '172.18.0.0/16'
            access: 'Allow'
            priority: 1100
            direction: 'Outbound'
            description: 'Allow VNet to AKS Service CIDR'
          }
        }
        {
          name: 'AllowVnetToAksPodCidr'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: '172.16.0.0/16'
            access: 'Allow'
            priority: 1110
            direction: 'Outbound'
            description: 'Allow VNet to AKS Pod CIDR'
          }
        }
        {
          name: 'AllowAksPodCidrToAksPodCidr'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '172.16.0.0/16'
            destinationAddressPrefix: '172.16.0.0/16'
            access: 'Allow'
            priority: 1120
            direction: 'Outbound'
            description: 'Allow AKS Pod CIDR to AKS Pod CIDR'
          }
        }
        {
          name: 'AllowOutboundAADAuth'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureActiveDirectory'
            access: 'Allow'
            priority: 2000
            direction: 'Outbound'
            description: 'Allow AAD Auth Outbound to AzureActiveDirectory'
          }
        }
        {
          name: 'AllowOutboundAzMonitor'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRanges: ['443', '1886']
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureMonitor'
            access: 'Allow'
            priority: 2010
            direction: 'Outbound'
            description: 'Allow AzMonitor Outbound ports(443,1886) from VirtualNetwork to AzureMonitor'
          }
        }
      ]
    }
    {
      name: 'TSTIMPNETNS1401-PrivateLink'
      purpose: 'PrivateLink'
      securityRules: []
    }
    {
      name: 'TSTIMPNETNS1401-PrivateEndpoint'
      purpose: 'Private Endpoints'
      securityRules: [
        {
          name: 'AllowAksPodCidrToPrivateEndpoints'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '172.16.0.0/16'
            destinationAddressPrefix: '10.179.144.64/26'
            access: 'Allow'
            priority: 1100
            direction: 'Inbound'
            description: 'Allow AKS Pod CIDR to Private Endpoints'
          }
        }
      ]
    }
    {
      name: 'TSTIMPNETNS1401-Reserved'
      purpose: 'Reserved'
      securityRules: []
    }
  ]
}

param vnetParams = {
  name: 'TSTIMPNETVN1401'
  addressPrefixes: ['10.179.132.0/22']
  dnsServers: [
    '10.176.0.4'
    '10.176.0.5'
  ]
  routeTable: {
    name: 'UDR-Spoke-Route-From-TSTIMPNETVN1401-01'
    virtualApplianceIp: '10.176.0.100'
  }
  subnets: [
    // AKS API Server, 14 usable addresses
    {
      name: 'TSTIMPNETSU4401'
      addressPrefix: '10.179.132.0/28'
      delegations: [
        {
          name: '0'
          properties: {
            serviceName: 'Microsoft.ContainerService/managedClusters'
          }
        }
      ]
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-TSTIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/TSTIMPNETNS1401-AKS'
    }
    // AKS System Node Pool, 14 usable addresses
    {
      name: 'TSTIMPNETSU4402'
      addressPrefix: '10.179.132.16/28'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-TSTIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/TSTIMPNETNS1401-AKS'
    }
    // PrivateLink, 30 usable addresses
    {
      name: 'TSTIMPNETSU4403'
      addressPrefix: '10.179.132.32/27'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-TSTIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/TSTIMPNETNS1401-PrivateLink'
    }
    // Private Endpoints, 62 usable addresses
    {
      name: 'TSTIMPNETSU4404'
      addressPrefix: '10.179.132.64/26'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-TSTIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/TSTIMPNETNS1401-PrivateEndpoint'
    }
    // App Gateway for Containers, see https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/container-networking
    {
      name: 'TSTIMPNETSU4405'
      addressPrefix: '10.179.133.0/24'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-TSTIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/TSTIMPNETNS1401-AKS'
    }
    // AKS User Node Pool, 253 usable addresses
    {
      name: 'TSTIMPNETSU4406'
      addressPrefix: '10.179.134.0/24'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-TSTIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/TSTIMPNETNS1401-AKS'
    }
    // Reserved, 126 usable addresses
    {
      name: 'TSTIMPNETSU4407'
      addressPrefix: '10.179.135.0/25'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-TSTIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/TSTIMPNETNS1401-Reserved'
    }
    // Reserved, 126 usable addresses
    {
      name: 'TSTIMPNETSU4408'
      addressPrefix: '10.179.135.128/25'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-TSTIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/TSTIMPNETNS1401-Reserved'
    }
  ]
}

// vim: set ts=2 sts=2 sw=2 et:
