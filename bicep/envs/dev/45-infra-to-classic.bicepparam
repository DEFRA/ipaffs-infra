using '../../45-infra-to-classic.bicep'

param builtInGroups = {
  contributors: '04b12060-3b12-49aa-a92a-d62873d8d29e' // AG-Azure-IMP_DEV1-Contributors
  owners: 'dbaf1ee8-c128-4f27-b159-791866210c2e' // AG-Azure-IMP_DEV1-Owners
}

param entraGroups = {}
param environment = 'DEV'
param subscriptionId = ''
param resourceGroupName = ''
param deployServicePrincipalObjectId = ''
param grafanaManagedIdentityPrincipalId = ''

param monitoringParams = {
  prometheusName: 'DEVIMPINFPR1401'
  grafanaName: 'DEVIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}
