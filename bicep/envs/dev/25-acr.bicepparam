using '../../40-infra.bicep'

param entraGroups = {}
param vnetName = 'DEVIMPNETVN1401'

param subnetNames = {
  aksApiServer: 'DEVIMPNETSU4401'
  aksSystemNodes: 'DEVIMPNETSU4402'
  aksUserNodes: 'DEVIMPNETSU4406'
  appGatewayForContainers: 'DEVIMPNETSU4405'
  privateEndpoints: 'DEVIMPNETSU4404'
}

param acrParams = {
  name: 'DEVIMPINFAC1401'
  sku: 'Premium'
  adminEnabled: true
}

// vim: set ts=2 sts=2 sw=2 et:
