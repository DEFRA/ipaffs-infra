using '../../45-infra-to-classic.bicep'

param builtInGroups = {
  contributors: 'b64aa742-daaf-4b7a-ab71-e7fd9e93905e' // AG-Azure-IMP_PRD1-Contributors
  owners: '3b6d27b3-b49b-44ad-8fc1-75bbf4d5c3fd' // AG-Azure-IMP_PRD1-Owners
}

param entraGroups = {}
param environment = 'PRD'
param deployServicePrincipalObjectId = ''
param grafanaManagedIdentityPrincipalId = ''
param subscriptionId = ''
param resourceGroupName = ''

param monitoringParams = {
  prometheusName: 'PRDIMPINFPR1401'
  grafanaName: 'PRDIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}
