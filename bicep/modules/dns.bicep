targetScope = 'resourceGroup'

param deploymentId string
param dnsParams object
param loadBalancerFrontendIpConfigurations array
param tags object

resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsParams.zoneName
}

resource loadBalancerARecord 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: dnsZone
  name: 'aks-lb'

  properties: {
    TTL: 300
    ARecords: [for config in loadBalancerFrontendIpConfigurations: {
      ipv4Address: config.properties.privateIPAddress
    }]
  }
}

resource loadBalancerWildcardARecord 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: dnsZone
  name: '*.aks'

  properties: {
    TTL: 300
    CNAMERecord: {
      cname: format('aks-lb.{0}', dnsZone.name)
    }
  }
}

// vim: set ts=2 sts=2 sw=2 et:
