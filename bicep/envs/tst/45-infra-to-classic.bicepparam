using '../../45-infra-to-classic.bicep'

param builtInGroups = {
  contributors: '89d5f0bd-ba3d-4779-95b6-66bf7f0ef487' // AG-Azure-IMP_TST1-Contributors
  owners: '8c073ada-277c-4716-a666-fb7470806d58' // AG-Azure-IMP_TST1-Owners
}

param entraGroups = {}
param environment = 'TST'
param subscriptionId = ''
param resourceGroupName = ''
param deployServicePrincipalObjectId = ''
param grafanaManagedIdentityPrincipalId = ''


param monitoringParams = {
  prometheusName: 'TSTIMPINFPR1401'
  grafanaName: 'TSTIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}

