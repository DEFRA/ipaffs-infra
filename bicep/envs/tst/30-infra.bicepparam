using '../../30-infra.bicep'

param builtInGroups = {
  contributors: '04b12060-3b12-49aa-a92a-d62873d8d29e' // AG-Azure-IMP_TST1-Contributors
  owners: 'dbaf1ee8-c128-4f27-b159-791866210c2e' // AG-Azure-IMP_TST1-Owners
}

param entraGroups = {}
param environment = 'TST'
param tenantId = ''
param vnetName = 'TSTIMPNETVN1401'

param subnetNames = {
  aksApiServer: 'TSTIMPNETSU4401'
  aksSystemNodes: 'TSTIMPNETSU4402'
  aksUserNodes: 'TSTIMPNETSU4406'
  appGatewayForContainers: 'TSTIMPNETSU4405'
  privateEndpoints: 'TSTIMPNETSU4404'
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
  userAssignedIdentityName: 'TSTIMPINFAK1401'
  version: '1.34'

  dnsServiceIp: '172.18.255.250'
  podCidrs: ['172.16.0.0/16']
  serviceCidrs: ['172.18.0.0/16']

  nodePools: {
    system: {
      minCount: 3
      maxCount: 5
      maxPods: 250
      vmSize: 'Standard_E2as_v7'
    }
    user: {
      minCount: 3
      maxCount: 12
      maxPods: 250
      vmSize: 'Standard_E16as_v7'
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
          name: 'AppPush: Paul Maguire'
          upn: 'paul.maguire@defra.onmicrosoftc.com'
        }
      ]
      emailRecipients: [
        {
          name: 'Email: Paul Maguire'
          email: 'paul.maguire@esynergy.co.uk'
        }
      ]
    }
  }
}

param asoParams = {
  managedIdentityName: 'TSTIMPINFMI1401-AzureServiceOperator'
}

param externalSecretsParams = {
  managedIdentityName: 'TSTIMPINFMI1401-ExternalSecrets'
}

param insightsParams = {
  name: 'TSTIMPINFIN1401'
}

param keyVaultParams = {
  name: 'TSTIMPINFKV1401'
  principalObjectIds: [
    builtInGroups.contributors
    builtInGroups.owners
  ]
}

param monitoringParams = {
  logAnalyticsName: 'TSTIMPINFLA1401'
  prometheusName: 'TSTIMPINFPR1401'
  grafanaName: 'TSTIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
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

param storageParams = {
  name: 'tstimpinfsto1401' // note: must be lowercase
}

// vim: set ts=2 sts=2 sw=2 et:
