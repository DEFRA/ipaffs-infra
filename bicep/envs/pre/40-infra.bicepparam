using '../../40-infra.bicep'

param builtInGroups = {
  contributors: '00000000-0000-0000-0000-000000000000' // AG-Azure-IMP_PRE1-Contributors
  owners: '11111111-1111-1111-1111-111111111111' // AG-Azure-IMP_PRE1-Owners
}

param acrResourceId = ''
param classicLocation = 'northeurope'
param classicResourceIds = {}
param entraGroups = {}
param environment = 'PRE'
param subnets = {}
param tenantId = ''
param vnetName = 'PREIMPNETVN1401'

param aksParams = {
  name: 'PREIMPINFAK1401'
  dnsPrefix: 'preimpinfak1401'
  nodeResourceGroup: 'PREIMPINFRG1402'
  sku: 'Standard'
  userAssignedIdentityName: 'PREIMPINFAK1401'
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
      name: 'PRE-IMP-DBA-Team'
      appRecipients: [
        {
          name: 'AppPush: Paul Maguire (Admin)'
          upn: 'a-paul.maguire@defra.onmicrosoftc.com'
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
  managedIdentityName: 'PREIMPINFMI1401-AzureServiceOperator'
}

param externalSecretsParams = {
  managedIdentityName: 'PREIMPINFMI1401-ExternalSecrets'
}

param insightsParams = {
  name: 'PREIMPINFIN1401'
}

param keyVaultParams = {
  name: 'PREIMPINFKV1401'
}

param monitoringParams = {
  logAnalyticsName: 'PREIMPINFLA1401'
  prometheusName: 'PREIMPINFPR1401'
  grafanaName: 'PREIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}

param redisParams = {
  name: 'preimpinfrd1401' // note: must be lowercase
}

param searchParams = {
  name: 'preimpinfas1401' // note: must be lowercase
  partitionCount: 1
  replicaCount: 2
  userAssignedIdentityName: 'PREIMPINFAS1401'
}

param sqlParams = {
  serverName: 'PREIMPDBSSQ1401'
  elasticPoolName: 'PREIMPDBSEP1401'
  maxSizeGiB: 10
  vCores: 2
}

param storageParams = {
  name: 'preimpinfst1401' // note: must be lowercase
}

// vim: set ts=2 sts=2 sw=2 et:
