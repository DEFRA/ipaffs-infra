using '../../40-infra.bicep'

param builtInGroups = {
  contributors: 'b64aa742-daaf-4b7a-ab71-e7fd9e93905e' // AG-Azure-IMP_PRD1-Contributors
  owners: '3b6d27b3-b49b-44ad-8fc1-75bbf4d5c3fd' // AG-Azure-IMP_PRD1-Owners
}

param classicLocation = 'northeurope'
param classicResourceIds = {}
param entraGroups = {}
param environment = 'PRD'
param subnets = {}
param tenantId = ''
param vnetName = 'PRDIMPNETVN1401'

param aksParams = {
  name: 'PRDIMPINFAK1401'
  dnsPrefix: 'prdimpinfak1401'
  nodeResourceGroup: 'PRDIMPINFRG1402'
  sku: 'Standard'
  userAssignedIdentityName: 'PRDIMPINFAK1401'
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
      name: 'PRD-IMP-DBA-Team'
      appRecipients: [
        {
          name: 'AppPush: Paul Maguire (Admin)'
          upn: 'a-paul.maguire@defra.onmicrosoft.com'
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
  managedIdentityName: 'PRDIMPINFMI1401-AzureServiceOperator'
}

param externalSecretsParams = {
  managedIdentityName: 'PRDIMPINFMI1401-ExternalSecrets'
}

param insightsParams = {
  name: 'PRDIMPINFIN1401'
}

param keyVaultParams = {
  name: 'PRDIMPINFKV1401'
}

param monitoringParams = {
  logAnalyticsName: 'PRDIMPINFLA1401'
  prometheusName: 'PRDIMPINFPR1401'
  grafanaName: 'PRDIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}

param redisParams = {
  name: 'prdimpinfrd1401' // note: must be lowercase
}

param searchParams = {
  name: 'prdimpinfas1401' // note: must be lowercase
  partitionCount: 1
  replicaCount: 2
  userAssignedIdentityName: 'PRDIMPINFAS1401'
}

param sqlParams = {
  serverName: 'PRDIMPDBSSQ1401'
  elasticPoolName: 'PRDIMPDBSEP1401'
  maxSizeGiB: 10
  vCores: 2
}

param storageParams = {
  name: 'prdimpinfst1401' // note: must be lowercase
}

// vim: set ts=2 sts=2 sw=2 et:
