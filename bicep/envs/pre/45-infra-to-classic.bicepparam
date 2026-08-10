using '../../40-infra.bicep'

param entraGroups = {}
param environment = 'PRE'
param deployServicePrincipalObjectId = ''
param grafanaManagedIdentityPrincipalId = ''

param monitoringParams = {
  prometheusName: 'PREIMPINFPR1401'
  grafanaName: 'PREIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}
