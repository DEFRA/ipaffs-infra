using '../../40-infra.bicep'

param entraGroups = {}
param environment = 'PRD'
param deployServicePrincipalObjectId = ''
param grafanaManagedIdentityPrincipalId = ''

param monitoringParams = {
  prometheusName: 'PRDIMPINFPR1401'
  grafanaName: 'PRDIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}
