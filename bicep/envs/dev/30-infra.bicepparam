using '../../30-infra.bicep'
extends 'common.bicepparam'

param entraGroups = {}
param vnetName = 'DEVIMPNETVN1401'

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

  dnsServiceIp: '172.18.255.250'
  podCidrs: ['172.16.0.0/16']
  serviceCidrs: ['172.18.0.0/16']

  nodePools: {
    system: {
      minCount: 3
      maxCount: 5
      maxPods: 250
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

param monitoringParams = {
  logAnalyticsName: 'DEVIMPINFLA1401'
  prometheusName: 'DEVIMPINFPR1401'
  grafanaName: 'DEVIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}

// vim: set ts=2 sts=2 sw=2 et:
