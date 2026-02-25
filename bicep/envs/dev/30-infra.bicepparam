using '../../30-infra.bicep'

param builtInGroups = {
  contributors: '04b12060-3b12-49aa-a92a-d62873d8d29e' // AG-Azure-IMP_DEV1-Contributors
  owners: 'dbaf1ee8-c128-4f27-b159-791866210c2e' // AG-Azure-IMP_DEV1-Owners
}

param entraGroups = {}
param environment = 'DEV'
param tenantId = ''
param vnetName = 'DEVIMPNETVN1401'

param subnetNames = {
  aksApiServer: 'DEVIMPNETSU4401'
  aksSystemNodes: 'DEVIMPNETSU4402'
  aksUserNodes: 'DEVIMPNETSU4406'
  appGatewayForContainers: 'DEVIMPNETSU4405'
  privateEndpoints: 'DEVIMPNETSU4404'
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

param alertsParams = {
  actionGroups: {
    notifyDba: {
      name: 'IMP-DBA-Team'
      appRecipients: [
        {
          name: 'Paul Maguire'
          upn: 'paul.maguire@defra.onmicrosoftc.com'
        }
      ]
      emailRecipients: [
        {
          name: 'Paul Maguire'
          email: 'paul.maguire@esynergy.co.uk'
        }
      ]
    }
  }
}

param asoParams = {
  managedIdentityName: 'DEVIMPINFMI1401-AzureServiceOperator'
}

param externalSecretsParams = {
  managedIdentityName: 'DEVIMPINFMI1401-ExternalSecrets'
}

param insightsParams = {
  name: 'DEVIMPINFIN1401'
}

param keyVaultParams = {
  name: 'DEVIMPINFKV1401'
  principalObjectIds: [
    builtInGroups.contributors
    builtInGroups.owners
  ]
}

param monitoringParams = {
  logAnalyticsName: 'DEVIMPINFLA1401'
  prometheusName: 'DEVIMPINFPR1401'
  grafanaName: 'DEVIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
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

param storageParams = {
  name: 'devimpinfsto1401' // note: must be lowercase
}

// vim: set ts=2 sts=2 sw=2 et:
