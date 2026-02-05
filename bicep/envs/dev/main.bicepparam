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
  userAssignedIdentityName: 'DEVIMPINFAK1401'
  version: '1.34'

  nodePools: {
    system: {
      minCount: 3
      maxCount: 5
      vmSize: 'Standard_E2as_v6'
    }
    user: {
      minCount: 3
      maxCount: 12
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
      name: 'DEVIMPNETNS1401'
      purpose: 'AKS ILB NSG'
      securityRules: [
        {
          name: 'AllowAnyInboundFromAzLB'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'AzureLoadBalancer'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 3600
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Any Inbound From AzLB'
          }
        }
        {
          name: 'DenyAnyOtherInbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Inbound'
          }
        }
        {
          name: 'AllowAnyTcpOutboundCidrRange'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 2080
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: [
              '10.179.105.0/24'
              '172.16.0.0/16'
            ]
            description: 'Allow Any Tcp Outbound from VirtualNetwork to npUser01cmn and Pod CIDR Ranges'
          }
        }
        {
          name: 'DenyAllOtherOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Outbound'
          }
        }
      ]
    }
    {
      name: 'DEVIMPNETNS1402'
      purpose: 'AKS System Node Pool NSG'
      securityRules: [
        {
          name: 'AllowVnetInternal'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationPortRange: '*'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 100
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow vNet to vNet communication on any port. Required for AKS nodes in the subnet'
          }
        }
        {
          name: 'AllowPodCidrAnyInbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 2000
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: [
              '172.16.0.0/16'
            ]
            destinationAddressPrefixes: []
            description: 'Allow Any port and any protocol Inbound from Pod CIDR Ranges to VirtualNetwork. This is required to allow POD to POD communication.'
          }
        }
        {
          name: 'AllowILbCidrInbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            sourceAddressPrefix: '10.179.104.0/27'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 2010
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: [
              '443'
              '80'
            ]
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Any Pod CIDR Ranges to Pod CIDR Ranges'
          }
        }
        {
          name: 'AllowUserNp01CidrAnyInbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '10.179.105.0/24'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 2020
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Any Node CIDR Ranges to Node CIDR Ranges. This is required to allow NODE to NODE communication.'
          }
        }
        {
          name: 'AllowAnyInboundFromAzLB'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'AzureLoadBalancer'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 3600
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Any Inbound From AzLB'
          }
        }
        {
          name: 'DenyAnyOtherInbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Inbound'
          }
        }
        {
          name: 'AllowDaisyResponse'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '172.24.155.113'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 3000
            direction: 'Inbound'
            sourcePortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Daisy Response Inbound'
          }
        }
        {
          name: 'AllowVNetAnyOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 2000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Any Outbound from VNet to VNet. This is required to allow POD to POD, Node to Node, Node to Pod and To private endpoints.'
          }
        }
        {
          name: 'AllowAADAuthOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureActiveDirectory'
            access: 'Allow'
            priority: 2020
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow AAD Auth Outbound from VirtualNetwork to AzureActiveDirectory'
          }
        }
        {
          name: 'AllowDevOpsSSHOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '22'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureDevOps'
            access: 'Allow'
            priority: 2030
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow DevOps SSH(Port 22) Outbound  from VirtualNetwork to AzureDevOps'
          }
        }
        {
          name: 'AllowAzMonitorOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureMonitor'
            access: 'Allow'
            priority: 2040
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: [
              '443'
              '1886'
            ]
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow AzMonitor Outbound ports(443,1886) from VirtualNetwork to AzureMonitor'
          }
        }
        {
          name: 'AllowAzAcrUksOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureContainerRegistry.UKSouth'
            access: 'Allow'
            priority: 2070
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow AzAcr Outbound port(443) from VirtualNetwork to AzureContainerRegistry.UKSouth'
          }
        }
        {
          name: 'AllowAzAcrUkwOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureContainerRegistry.UKWest'
            access: 'Allow'
            priority: 2075
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow AzAcr Outbound port(443) from VirtualNetwork to AzureContainerRegistry.UKWest'
          }
        }
        {
          name: 'AllowAzKvltUksOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureKeyVault.UKSouth'
            access: 'Allow'
            priority: 2090
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Az Key vault Outbound port(443) from VirtualNetwork to AzureKeyVault.UKSouth'
          }
        }
        {
          name: 'AllowAzKvltUkwOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureKeyVault.UKWest'
            access: 'Allow'
            priority: 2095
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Az Key vault Outbound port(443) from VirtualNetwork to AzureKeyVault.UKWest'
          }
        }
        {
          name: 'AllowHttpsForFluxOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'Internet'
            access: 'Allow'
            priority: 3900
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Https Outbound port(443) from VirtualNetwork to Internet'
          }
        }
        {
          name: 'DenyAllOtherOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Outbound'
          }
        }
        {
          name: 'AllowOutboundtoDaisy'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: '172.24.155.113'
            access: 'Allow'
            priority: 3000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRange: '1433'
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Outbound to Daisy'
          }
        }
      ]
    }
    {
      name: 'DEVIMPNETNS1403'
      purpose: 'PrivateLink NSG'
      securityRules: [
        {
          name: 'DenyAllOtherOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Outbound'
          }
        }
      ]
    }
    {
      name: 'DEVIMPNETNS1404'
      purpose: 'Private Endpoints NSG'
      securityRules: [
        {
          name: 'DenyAllOtherOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Outbound'
          }
        }
      ]
    }
    {
      name: 'DEVIMPNETNS1405'
      purpose: 'App Gateway for Containers NSG'
      securityRules: [
        {
          name: 'DenyAllOtherOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Outbound'
          }
        }
      ]
    }
    {
      name: 'DEVIMPNETNS1406'
      purpose: 'AKS User Node Pool NSG'
      securityRules: [
        {
          name: 'AllowPodCidrAnyInbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 2000
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: [
              '172.16.0.0/16'
            ]
            destinationAddressPrefixes: []
            description: 'Allow Any port and any protocol Inbound from Pod CIDR Ranges to VirtualNetwork. This is required to allow POD to POD communication.'
          }
        }
        {
          name: 'AllowSystemNp01CidrAnyInbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '10.179.104.128/25'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 2010
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Any Node CIDR Ranges to Node CIDR Ranges. This is required to allow NODE to NODE communication.'
          }
        }
        {
          name: 'AllowAnyInboundFromAzLB'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'AzureLoadBalancer'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 3600
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Any Inbound From AzLB'
          }
        }
        {
          name: 'DenyAnyOtherInbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Inbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Inbound'
          }
        }
        {
          name: 'AllowVNetAnyOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 2000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Any Outbound from VNet to VNet. This is required to allow POD to POD, Node to Node, Node to Pod and To private endpoints.'
          }
        }
        {
          name: 'AllowAADAuthOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureActiveDirectory'
            access: 'Allow'
            priority: 2020
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow AAD Auth Outbound port(443) from VirtualNetwork to AzureActiveDirectory'
          }
        }
        {
          name: 'AllowAzMonitorOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureMonitor'
            access: 'Allow'
            priority: 2040
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: [
              '443'
              '1886'
            ]
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow AzMonitor Outbound ports(443,1886) from VirtualNetwork to AzureMonitor'
          }
        }
        {
          name: 'AllowAzAcrUksOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureContainerRegistry.UKSouth'
            access: 'Allow'
            priority: 2070
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow AzAcr Outbound port(443) from VirtualNetwork to AzureContainerRegistry.UKSouth'
          }
        }
        {
          name: 'AllowAzAcrUkwOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureContainerRegistry.UKWest'
            access: 'Allow'
            priority: 2075
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow AzAcr Outbound port(443) from VirtualNetwork to AzureContainerRegistry.UKWest'
          }
        }
        {
          name: 'AllowAzKvltUksOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureKeyVault.UKSouth'
            access: 'Allow'
            priority: 2090
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Az Key vault Outbound port(443) from VirtualNetwork to AzureKeyVault.UKSouth'
          }
        }
        {
          name: 'AllowAzKvltUkwOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'AzureKeyVault.UKWest'
            access: 'Allow'
            priority: 2095
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Az Key vault Outbound port(443) from VirtualNetwork to AzureKeyVault.UKWest'
          }
        }
        {
          name: 'AllowHttpsForFluxOutbound'
          properties: {
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'Internet'
            access: 'Allow'
            priority: 3900
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Allow Https Outbound port(443) from VirtualNetwork to Internet'
          }
        }
        {
          name: 'DenyAllOtherOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Outbound'
          }
        }
      ]
    }
    {
      name: 'DEVIMPNETNS1407'
      purpose: 'Reserved NSG'
      securityRules: [
        {
          name: 'DenyAllOtherOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Outbound'
          }
        }
      ]
    }
    {
      name: 'DEVIMPNETNS1408'
      purpose: 'Reserved NSG'
      securityRules: [
        {
          name: 'DenyAllOtherOutbound'
          properties: {
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            access: 'Deny'
            priority: 4000
            direction: 'Outbound'
            sourcePortRanges: []
            destinationPortRanges: []
            sourceAddressPrefixes: []
            destinationAddressPrefixes: []
            description: 'Deny All Other Outbound'
          }
        }
      ]
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
          name: 'Microsoft.ContainerService/managedClusters'
          id: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/availableDelegations/Microsoft.ContainerService.managedClusters'
          type: 'Microsoft.Network/availableDelegations'
        }
      ]
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1401'
    }
    // AKS System Node Pool, 14 usable addresses
    {
      name: 'DEVIMPNETSU4402'
      addressPrefix: '10.179.144.16/28'
      delegations: [
        {
          name: 'Microsoft.ContainerService/managedClusters'
          id: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/availableDelegations/Microsoft.ContainerService.managedClusters'
          type: 'Microsoft.Network/availableDelegations'
        }
      ]
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1402'
    }
    // PrivateLink, 30 usable addresses
    {
      name: 'DEVIMPNETSU4403'
      addressPrefix: '10.179.144.32/27'
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1403'
    }
    // Private Endpoints, 62 usable addresses
    {
      name: 'DEVIMPNETSU4404'
      addressPrefix: '10.179.144.64/26'
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1404'
    }
    // App Gateway for Containers, see https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/container-networking
    {
      name: 'DEVIMPNETSU4405'
      addressPrefix: '10.179.145.0/24'
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1405'
    }
    // AKS User Node Pool, 253 usable addresses
    {
      name: 'DEVIMPNETSU4406'
      addressPrefix: '10.179.146.0/24'
      delegations: [
        {
          name: 'Microsoft.ContainerService/managedClusters'
          id: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/availableDelegations/Microsoft.ContainerService.managedClusters'
          type: 'Microsoft.Network/availableDelegations'
        }
      ]
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1406'
    }
    // Reserved, 126 usable addresses
    {
      name: 'DEVIMPNETSU4407'
      addressPrefix: '10.179.147.0/25'
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1407'
    }
    // Reserved, 126 usable addresses
    {
      name: 'DEVIMPNETSU4408'
      addressPrefix: '10.179.147.128/25'
      serviceEndpoints: []
      routeTableId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-DEVIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401/providers/Microsoft.Network/networkSecurityGroups/DEVIMPNETNS1408'
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
