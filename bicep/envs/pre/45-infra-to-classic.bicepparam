using '../../45-infra-to-classic.bicep'

param builtInGroups = {
  contributors: '80a5fda0-7d36-4c3a-a5de-44a6a525fd2d' // AG-Azure-IMP_PRE1-Contributors
  owners: '400ebb88-9bab-427b-b282-86e9bcc010ab' // AG-Azure-IMP_PRE1-Owners
}

param entraGroups = {}
param environment = 'PRE'
param subscriptionId = ''
param resourceGroupName = ''
param deployServicePrincipalObjectId = ''
param grafanaManagedIdentityPrincipalId = ''

param monitoringParams = {
  prometheusName: 'PREIMPINFPR1401'
  grafanaName: 'PREIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}
