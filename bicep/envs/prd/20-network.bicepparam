using '../../20-network.bicep'

param environment = 'PRD'

param subnetNames = {
  aksApiServer: 'PRDIMPNETSU4401'
  aksSystemNodes: 'PRDIMPNETSU4402'
  aksUserNodes: 'PRDIMPNETSU4406'
  appGatewayForContainers: 'PRDIMPNETSU4405'
  privateEndpoints: 'PRDIMPNETSU4404'
}

param nsgParams = {
  networkSecurityGroups: [
    {
      name: 'PRDIMPNETNS1401-AKS'
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
          name: 'AllowInboundAzureDevOps'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'AzureDevOps'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 1050
            direction: 'Inbound'
            description: 'Allow all inbound traffic from Azure DevOps'
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
          name: 'AllowVnetToAksServiceCidr'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: '172.18.0.0/16'
            access: 'Allow'
            priority: 2000
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
            priority: 2010
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
            priority: 2020
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
            priority: 3000
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
            priority: 3010
            direction: 'Outbound'
            description: 'Allow AzMonitor Outbound ports(443,1886) from VirtualNetwork to AzureMonitor'
          }
        }
      ]
    }
    {
      name: 'PRDIMPNETNS1401-PrivateLink'
      purpose: 'PrivateLink'
      securityRules: []
    }
    {
      name: 'PRDIMPNETNS1401-PrivateEndpoint'
      purpose: 'Private Endpoints'
      securityRules: [
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
          name: 'AllowAksPodCidrToPrivateEndpoints'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '172.16.0.0/16'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 2000
            direction: 'Inbound'
            description: 'Allow AKS Pod CIDR to Private Endpoints'
          }
        }
      ]
    }
    {
      name: 'PRDIMPNETNS1401-Reserved'
      purpose: 'Reserved'
      securityRules: []
    }
  ]
}

param vnetParams = {
  name: 'PRDIMPNETVN1401'
  addressPrefixes: ['10.179.140.0/22']
  dnsServers: [
    '10.176.0.4'
    '10.176.0.5'
  ]
  routeTable: {
    name: 'UDR-Spoke-Route-From-PRDIMPNETVN1401-01'
    virtualApplianceIp: '10.176.0.100'
  }
  classicVnetResourceId: '/subscriptions/79ee8c9c-33d7-4074-9f4c-a13f07c62a33/resourceGroups/PRDINFNETRGP001/providers/Microsoft.Network/virtualNetworks/PRDINFNETVNT001'
  principalsNeedingContributor: [
    '6ab71598-0565-4705-bb77-5070ea4916cb' // ADO-DefraGovUK-AZR-PRD_IMP (ADO service connection)
  ]
  subnets: [
    // AKS API Server, 14 usable addresses
    {
      name: 'PRDIMPNETSU4401'
      addressPrefix: '10.179.140.0/28'
      delegations: [
        {
          name: '0'
          properties: {
            serviceName: 'Microsoft.ContainerService/managedClusters'
          }
        }
      ]
      serviceEndpoints: [
        {
          service: 'Microsoft.ContainerRegistry'
        }
        {
          service: 'Microsoft.KeyVault'
        }
        {
          service: 'Microsoft.ServiceBus'
        }
      ]
      routeTableId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-PRDIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/PRDIMPNETNS1401-AKS'
    }
    // AKS System Node Pool, 14 usable addresses
    {
      name: 'PRDIMPNETSU4402'
      addressPrefix: '10.179.140.16/28'
      delegations: []
      serviceEndpoints: [
        {
          service: 'Microsoft.ContainerRegistry'
        }
        {
          service: 'Microsoft.KeyVault'
        }
        {
          service: 'Microsoft.ServiceBus'
        }
      ]
      routeTableId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-PRDIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/PRDIMPNETNS1401-AKS'
    }
    // PrivateLink, 30 usable addresses
    {
      name: 'PRDIMPNETSU4403'
      addressPrefix: '10.179.140.32/27'
      delegations: []
      serviceEndpoints: []
      privateEndpointNetworkPolicies: 'Disabled'
      privateLinkServiceNetworkPolicies: 'Disabled'
      routeTableId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-PRDIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/PRDIMPNETNS1401-PrivateLink'
    }
    // Private Endpoints, 62 usable addresses
    {
      name: 'PRDIMPNETSU4404'
      addressPrefix: '10.179.140.64/26'
      delegations: []
      serviceEndpoints: []
      privateEndpointNetworkPolicies: 'Disabled'
      privateLinkServiceNetworkPolicies: 'Disabled'
      routeTableId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-PRDIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/PRDIMPNETNS1401-PrivateEndpoint'
    }
    // App Gateway for Containers, see https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/container-networking
    {
      name: 'PRDIMPNETSU4405'
      addressPrefix: '10.179.141.0/24'
      serviceEndpoints: []
      routeTableId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-PRDIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/PRDIMPNETNS1401-AKS'
    }
    // AKS User Node Pool, 253 usable addresses
    {
      name: 'PRDIMPNETSU4406'
      addressPrefix: '10.179.142.0/24'
      delegations: []
      serviceEndpoints: [
        {
          service: 'Microsoft.ContainerRegistry'
        }
        {
          service: 'Microsoft.KeyVault'
        }
        {
          service: 'Microsoft.ServiceBus'
        }
      ]
      routeTableId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-PRDIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/PRDIMPNETNS1401-AKS'
    }
    // Reserved, 126 usable addresses
    {
      name: 'PRDIMPNETSU4407'
      addressPrefix: '10.179.143.0/25'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-PRDIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/PRDIMPNETNS1401-Reserved'
    }
    // Reserved, 126 usable addresses
    {
      name: 'PRDIMPNETSU4408'
      addressPrefix: '10.179.143.128/25'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-PRDIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/PRDIMPNETNS1401-Reserved'
    }
  ]
}

// vim: set ts=2 sts=2 sw=2 et:
