using '../../30-infra.bicep'

param builtInGroups = {
  contributors: '04b12060-3b12-49aa-a92a-d62873d8d29e' // AG-Azure-IMP_TST1-Contributors
  owners: 'dbaf1ee8-c128-4f27-b159-791866210c2e' // AG-Azure-IMP_TST1-Owners
}

param entraGroups = {}
param environment = 'TST'
param tenantId = ''
param vnetName = 'DEVIMPNETVN1401'

param subnetNames = {
  aksApiServer: 'TSTIMPNETSU4401'
  aksSystemNodes: 'TSTIMPNETSU4402'
  aksUserNodes: 'TSTIMPNETSU4406'
  appGatewayForContainers: 'TSTIMPNETSU4405'
  privateEndpoints: 'TSTIMPNETSU4404'
  privateLink: 'TSTIMPNETSU4403'
}

param acrParams = {
  name: 'TSTIMPINFAC1401'
  sku: 'Premium'
  adminEnabled: true
}

param aksParams = {
  name: 'TSTIMPINFAK1401'
  dnsPrefix: 'tstimpinfak1401'
  nodeResourceGroup: 'TSTIMPINFRG1402'
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
  managedIdentityName: 'TSTIMPINFMI1401-AzureServiceOperator'
}

param externalSecretsParams = {
  managedIdentityName: 'TSTIMPINFMI1401-ExternalSecrets'
}

param keyVaultParams = {
  name: 'TSTIMPINFKV1401'
  principalObjectIds: [
    builtInGroups.contributors
    builtInGroups.owners
  ]
}

param redisParams = {
  name: 'tstimpinfrd1401' // note: must be lowercase
}

param searchParams = {
  name: 'tstimpinfas1401' // note: must be lowercase
  partitionCount: 1
  replicaCount: 2
}

param sqlParams = {
  serverName: 'TSTIMPDBSSQ1401'
  elasticPoolName: 'TSTIMPDBSEP1401'
  maxSizeGiB: 10
  vCores: 2
}

param monitoringParams = {
  logAnalyticsName: 'TSTIMPINFLA1401'
  prometheusName: 'TSTIMPINFPR1401'
  grafanaName: 'TSTIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}

// vim: set ts=2 sts=2 sw=2 et:
