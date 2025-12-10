using '../../main.bicep'

param environment = 'POC'
param tenantId = ''

param acrParams = {
  name: 'POCIMPINFAC1401'
  sku: 'Premium'
  adminEnabled: true
}

param aksParams = {
  name: 'POCIMPINFAK1401'
  dnsPrefix: 'POCIMPINFAK1401'
  version: '1.32'
  sshRSAPublicKey: 'ssh-rsa AAAA...'
  subnetId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/virtualNetworks/POCIMPNETVN1401/subnets/POCIMPNETSU4402'
  adminUserName: 'adminuser'
  adminGroupObjectIDs: [
    '65c89463-4af9-4520-bc82-77f0ead4e424' // AG-Azure-IMP_POC-SQLAdmins
  ]
}

param asoParams = {
  managedIdentityName: 'POCIMPINFMI1401-AzureServiceOperator'
}

param keyVaultParams = {
  name: 'POCIMPINFKV1401'
  principalObjectIds: [
    '4b2fbef7-de9d-4836-a44e-46c56aad3d9e' // AG-Azure-IMP_POC1-Contributors
  ]
}

param nsgParams = {
  networkSecurityGroups: [
    {
      name: 'POCIMPNETNS1401'
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
      name: 'POCIMPNETNS1402'
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
      name: 'POCIMPNETNS1403'
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
  ]
}

param sqlParams = {
  adminGroupName: 'AG-Azure-IMP_POC-SQLAdmins'
  adminGroupObjectId: '65c89463-4af9-4520-bc82-77f0ead4e424'
  serverName: 'POCIMPDBSSQ1401'
  elasticPoolName: 'POCIMPDBSEP1401'
  maxSizeGiB: 10
  vCores: 2
}

param vnetParams = {
  name: 'POCIMPNETVN1401'
  addressPrefixes: ['10.179.104.0/22']
  dnsServers: [
    '10.176.0.4'
    '10.176.0.5'
  ]
  routeTable: {
    name: 'UDR-Spoke-Route-From-POCIMPNETVN1401-01'
    virtualApplianceIp: '10.176.0.100'
  }
  subnets: [
    {
      name: 'POCIMPNETSU4401'
      addressPrefix: '10.179.104.0/27'
      serviceEndpoints: []
      routeTableId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-POCIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/networkSecurityGroups/POCIMPNETNS1401'
    }
    {
      name: 'POCIMPNETSU4402'
      addressPrefix: '10.179.104.128/25'
      serviceEndpoints: []
      routeTableId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-POCIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/networkSecurityGroups/POCIMPNETNS1402'
    }
    {
      name: 'POCIMPNETSU4403'
      addressPrefix: '10.179.105.0/24'
      serviceEndpoints: []
      routeTableId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-POCIMPNETVN1401-01'
      networkSecurityGroupId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/networkSecurityGroups/POCIMPNETNS1403'
    }
    {
      name: 'POCIMPNETSU4404'
      addressPrefix: '10.179.106.0/25'
      serviceEndpoints: []
      routeTableId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-POCIMPNETVN1401-01'
    }
    {
      name: 'POCIMPNETSU4405'
      addressPrefix: '10.179.106.128/25'
      serviceEndpoints: []
      routeTableId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-POCIMPNETVN1401-01'
    }
    {
      name: 'POCIMPNETSU4406'
      addressPrefix: '10.179.107.0/24'
      serviceEndpoints: []
      routeTableId: '/subscriptions/cfa4ccd1-5a5e-420c-9bca-03218a43e46d/resourceGroups/POCIMPNETNS1401/providers/Microsoft.Network/routeTables/UDR-Spoke-Route-From-POCIMPNETVN1401-01'
    }
  ]
}

// vim: set ts=2 sts=2 sw=2 et:
