using '../../main.bicep'

param environment = 'DEV'
param tenantId = ''

param builtInGroups = {
  contributors: '04b12060-3b12-49aa-a92a-d62873d8d29e' // AG-Azure-IMP_DEV1-Contributors
  owners: 'dbaf1ee8-c128-4f27-b159-791866210c2e' // AG-Azure-IMP_DEV1-Owners
}

param entraGroups = {}

param subnetNames = {
  aksApiServer: 'DEVIMPNETSU4401'
  aksSystemNodes: 'DEVIMPNETSU4402'
  aksUserNodes: 'DEVIMPNETSU4406'
  appGatewayForContainers: 'DEVIMPNETSU4405'
  privateEndpoints: 'DEVIMPNETSU4404'
  privateLink: 'DEVIMPNETSU4403'
}

param acrParams = {
  name: 'DEVIMPINFAC1401'
  sku: 'Premium'
  adminEnabled: true
}

param aksParams = {
  name: 'DEVIMPINFAK1401'
  dnsPrefix: 'devimpinfak1401'
  nodeResourceGroup: 'DEVIMPINFRG1402'
  sku: 'Standard'
  userAssignedIdentityName: 'DEVIMPINFAK1401'
  version: '1.34'

  nodePools: {
    system: {
      minCount: 3
      maxCount: 5
      maxPods: 120
      vmSize: 'Standard_E2as_v6'
    }
    user: {
      minCount: 3
      maxCount: 12
      maxPods: 250
      vmSize: 'Standard_E16as_v6'
    }
  }
  adminGroupObjectIDs: [
    builtInGroups.contributors
    builtInGroups.owners
  ]
}

param asoParams = {
  managedIdentityName: 'DEVIMPINFMI1401-AzureServiceOperator'
}

param externalSecretsParams = {
  managedIdentityName: 'DEVIMPINFMI1401-ExternalSecrets'
}

param keyVaultParams = {
  name: 'DEVIMPINFKV1401'
  principalObjectIds: [
    builtInGroups.contributors
    builtInGroups.owners
  ]
}

param nsgParams = {
  networkSecurityGroups: [
    {
      name: 'DEVIMPNETNS1401-AKS'
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
            destinationAddressPrefix: '10.0.0.0/16'
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
            destinationAddressPrefix: '10.240.0.0/16'
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
            sourceAddressPrefix: '10.240.0.0/16'
            destinationAddressPrefix: '10.240.0.0/16'
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
      name: 'DEVIMPNETNS1401-PrivateLink'
      purpose: 'PrivateLink'
      securityRules: []
    }
    {
      name: 'DEVIMPNETNS1401-PrivateEndpoint'
      purpose: 'Private Endpoints'
      securityRules: [
        {
          name: 'AllowAksPodCidrToPrivateEndpoints'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '10.240.0.0/16'
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
      name: 'DEVIMPNETNS1401-Reserved'
      purpose: 'Reserved'
      securityRules: []
    }
  ]
}

param redisParams = {
  name: 'devimpinfrd1401' // note: must be lowercase
}

param searchParams = {
  name: 'devimpinfas1401' // note: must be lowercase
  partitionCount: 1
  replicaCount: 2
}

param sqlParams = {
  serverName: 'DEVIMPDBSSQ1401'
  elasticPoolName: 'DEVIMPDBSEP1401'
  maxSizeGiB: 10
  vCores: 2
}

param vnetParams = {
  name: 'DEVIMPNETVN1401'
  addressPrefixes: ['10.179.144.0/22']
  dnsServers: [
    '10.176.0.4'
    '10.176.0.5'
  ]
  routeTable: {
    name: 'UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
    virtualApplianceIp: '10.176.0.100'
  }
  subnets: [
    // AKS API Server, 14 usable addresses
    {
      name: 'DEVIMPNETSU4401'
      addressPrefix: '10.179.144.0/28'
      delegations: [
        {
          name: '0'
          properties: {
            serviceName: 'Microsoft.ContainerService/managedClusters'
          }
        }
      ]
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1401-AKS'
    }
    // AKS System Node Pool, 14 usable addresses
    {
      name: 'DEVIMPNETSU4402'
      addressPrefix: '10.179.144.16/28'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1401-AKS'
    }
    // PrivateLink, 30 usable addresses
    {
      name: 'DEVIMPNETSU4403'
      addressPrefix: '10.179.144.32/27'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1401-PrivateLink'
    }
    // Private Endpoints, 62 usable addresses
    {
      name: 'DEVIMPNETSU4404'
      addressPrefix: '10.179.144.64/26'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1401-PrivateEndpoint'
    }
    // App Gateway for Containers, see https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/container-networking
    {
      name: 'DEVIMPNETSU4405'
      addressPrefix: '10.179.145.0/24'
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1401-AKS'
    }
    // AKS User Node Pool, 253 usable addresses
    {
      name: 'DEVIMPNETSU4406'
      addressPrefix: '10.179.146.0/24'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1401-AKS'
    }
    // Reserved, 126 usable addresses
    {
      name: 'DEVIMPNETSU4407'
      addressPrefix: '10.179.147.0/25'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1401-Reserved'
    }
    // Reserved, 126 usable addresses
    {
      name: 'DEVIMPNETSU4408'
      addressPrefix: '10.179.147.128/25'
      delegations: []
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1401-Reserved'
    }
  ]
}

param monitoringParams = {
  logAnalyticsName: 'DEVIMPINFLA1401'
  prometheusName: 'DEVIMPINFPR1401'
  grafanaName: 'DEVIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}

// vim: set ts=2 sts=2 sw=2 et:
