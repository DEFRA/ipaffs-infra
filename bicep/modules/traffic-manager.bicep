targetScope = 'resourceGroup'

param trafficManagerParams object
param tags object

resource trafficManager 'Microsoft.Network/trafficManagerProfiles@2022-04-01' = {
  name: trafficManagerParams.name
  location: 'global'
  tags: tags
  properties: {
    profileStatus: 'Enabled'
    trafficRoutingMethod: 'Weighted'
    dnsConfig: {
      relativeName: trafficManagerParams.relativeName
      ttl: trafficManagerParams.ttl
    }
    monitorConfig: {
      protocol: trafficManagerParams.monitor.protocol
      port: trafficManagerParams.monitor.port
      path: trafficManagerParams.monitor.path
      intervalInSeconds: trafficManagerParams.monitor.intervalInSeconds
      timeoutInSeconds: trafficManagerParams.monitor.timeoutInSeconds
      toleratedNumberOfFailures: trafficManagerParams.monitor.toleratedNumberOfFailures
    }
  }
}

resource endpoints 'Microsoft.Network/trafficManagerProfiles/externalEndpoints@2022-04-01' = [
  for endpoint in trafficManagerParams.endpoints: {
    name: '${trafficManager.name}/${endpoint.name}'
    properties: {
      endpointStatus: endpoint.enabled ? 'Enabled' : 'Disabled'
      target: endpoint.target
      weight: endpoint.weight
    }
  }
]

output trafficManagerFqdn string = trafficManager.properties.dnsConfig.fqdn

// vim: set ts=2 sts=2 sw=2 et:
