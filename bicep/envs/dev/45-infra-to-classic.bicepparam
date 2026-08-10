using '../../45-infra-to-classic.bicep'

param entraGroups = {}
param environment = 'DEV'
param deployServicePrincipalObjectId = ''
param grafanaManagedIdentityPrincipalId = ''

param monitoringParams = {
  prometheusName: 'DEVIMPINFPR1401'
  grafanaName: 'DEVIMPINFGA1401'
  principalObjectId: builtInGroups.contributors
}
